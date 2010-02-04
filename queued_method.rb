module QueuedMethod
  module InstanceMethods
    #
    # This creates the basic queued_method caching keys.
    # using the base ActiveRecord cache_key method
    # so caches will be invalidated if the object's 
    # updated_at changes. 
    #
    # class_name/id-updated_at/queued_method/method_name
    #
    # If you don't want the queued_method to be invalidated
    # when the object changes, override this method
    def queued_method_key(*args)
      "#{cache_key}/queued_method/#{args.join '/'}"
    end

    # simple helper for the queuing key
    def queued_method_queued_key(method)
      queued_method_key method, 'queued'
    end  
    
    # check to see if our cache has expired
    # if the :expires_in key is not set, it will
    # only expire when the object changes unless
    # underlying method is called with :force => true
    def queued_method_expired?(data)
      data.nil? or ((data[:expires_at].class.name =~ /Time/) and data[:expires_at] < Time.now)
    end
  
    # check to see if the cache is stale.
    # If the :stale_in key is not set, objects
    # will only be stale if expired 
    def queued_method_stale?(data)
      queued_method_expired?(data) or ((data[:stale_at].class.name =~ /Time/) and data[:stale_at] < Time.now)
    end
  
    # Add the stale method to the job queue as 
    # long as there isn't already a job queued or processing
    def queued_method_queue(method)
      nice_queued_method queued_method_queued_key(method), false do
        queued_method_job_queue method
      end
    end
    
    # method to add job to queue.  Override this if you
    # are using something other than Delayed::Job
    def queued_method_job_queue(method)
      self.send_later :queued_method_job, method
    end
    
    # processes the job queue as long as a job isn't 
    # already processing. 
    def queued_method_job(method)
      nice_queued_method queued_method_key(method, 'processing') do
        if queued_method_stale?(queued_method_data(method))
          caching_method method
        end
      end      
    end
    
    # A wrapper to sort act a little like thread safetey. 
    # if a key is not set, it sets the key and yeilds the block.
    # Once finished, it clears the key unless clear_key is set to false.
    # This is handy for adding a key when queing a job and then
    # removing once completed
    def nice_queued_method(caching_key, clear_key = true, &block)
      unless Rails.cache.read(caching_key)
        Rails.cache.write caching_key, {:started => Time.now}
        yield 
        Rails.cache.delete caching_key if clear_key
      end
    end
  
    # caching_method actually calls the underlying method, 
    # writes it to the cache, and clears any outstanding
    # blocking keys
    def caching_method(method)      
      returning send("_queued_method_#{method}") do |results|
        Rails.cache.write queued_method_key(method), results
        Rails.cache.delete queued_method_queued_key(method)
      end
    end
    
    # convience method to read the underlying data from the cache
    def queued_method_data(method)
      Rails.cache.read(queued_method_key(method))
    end
    
    # The base function called in place of the original function.
    # Like the bedroom on "Cribs," this is where the magic happens.
    #
    # The base method is called. If the cache is fresh, it returns the info.
    # If the cache is not expired but is stale, returns the stale info and 
    # queues a refresh. If the cache is expired, the underlying function 
    # is called immediately (and cached) or the :fallback method is called and the
    # original method is queued.
    #
    # Options:
    # :force => true
    #     Dump the cache and process RIGHT NOW without queue. 
    #
    # :fallback => :method_name
    #     Optional function to call if the cache is expired in place
    #     of calling inline
    def queued_method(method, options = {})
      caching_key = queued_method_key method
      Rails.cache.delete(caching_key) if options[:force]
      data = queued_method_data(method) 
      if queued_method_expired?(data)
        puts "expired #{Time.now} : #{data.inspect}"
        if options[:fallback]
          data = {:results => send(options[:fallback])}
          queued_method_queue(method)
        else
          data = caching_method(method)
        end
      else
        queued_method_queue(method) if queued_method_stale?(data)
      end
      
      data[:results]
    end
  end
  
  def queued_method(method, options = {})
    original_method = :"_original_#{method}"

    class_eval <<-EOS, __FILE__, __LINE__
      include InstanceMethods
      
      if method_defined?(:#{original_method})       
        raise "Already created _queued_method for #{method}"
      end
      alias #{original_method} #{method}
      
      if instance_method(:#{method}).arity != 0
        raise "Only methods without arguments are allowed."
      end
      
      if (#{method == options[:fallback]})
        raise "The fallback method must be different from the queued method."
      end
      
      def #{method}(force = #{!!options[:force]})
        queued_method :#{method}, {:force => force, :fallback => #{options[:fallback] ?  options[:fallback].to_s.inspect : 'nil'}}
      end
      
      def _queued_method_#{method}
        {
          :results  => #{original_method},
          :stale_at => (Time.now + #{options[:stale_in].to_i}),
          :expires_at => (Time.now + #{options[:expires_in].to_i})
        }
      end
      if private_method_defined?(#{original_method.inspect})
        private #{method.inspect}
      end
    EOS
  
  end
end


