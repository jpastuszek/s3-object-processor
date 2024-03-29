require 'thread'
Thread.abort_on_exception = true

class Runnable
	def on_finish(&callback)
		(@on_finish ||= []) << callback
		self
	end

	def run
		@thread = Thread.new do
			begin
				yield
			rescue Interrupt
				# ignored
			ensure
				begin
					@on_finish.each{|on_finish| on_finish.call} if @on_finish
				rescue
					# ignored
				end
			end
		end
		self
	end

	def join
		@thread.join if @thread
	end
end

class Lister < Runnable
	def initialize(bucket, key_queue, fetch_size, max_keys = nil)
		@bucket = bucket
		@key_queue = key_queue
		@fetch_size = fetch_size
		@max_keys = max_keys
	end

	def on_keys_chunk(&callback)
		@on_keys_chunk = callback
		self
	end

	def run(prefix = nil)
		super() do
			catch :done do
				marker = ''
				total_keys = 0
				loop do
					keys_chunk = @bucket.keys(prefix: prefix, 'max-keys' => @fetch_size, marker: marker)
					break if keys_chunk.empty?
					@on_keys_chunk.call(keys_chunk) if @on_keys_chunk
					keys_chunk.each do |key|
						throw :done if @max_keys and total_keys >= @max_keys
						@key_queue << key
						total_keys += 1
					end
					marker = keys_chunk.last.name
				end
			end
		end
	end
end

class ListLister < Runnable
	def initialize(bucket, key_queue, max_keys = nil)
		@bucket = bucket
		@key_queue = key_queue
		@max_keys = max_keys
	end

	def on_keys_chunk(&callback)
		@on_keys_chunk = callback
		self
	end

	def run(list)
		super() do
			total_keys = 0
			@on_keys_chunk.call(list) if @on_keys_chunk
			list.each do |key|
				@key_queue << @bucket.key(key)
				break if @max_keys and total_keys >= @max_keys
				total_keys += 1
			end
		end
	end
end

class Worker < Runnable
	def initialize(no, key_queue, &process_key)
		@no = no
		@key_queue = key_queue
		@process_key = process_key
	end

	def on_error(&callback)
		@on_error = callback
		self
	end

	def run
		super do
			until (key = @key_queue.pop) == :end
				begin
					@process_key.call(key)
				rescue => error
					@on_error.call(key, error) if @on_error
				end
			end
		end
	end
end

class Reporter < Runnable
	class Report
		class DSL
			attr_reader :update_callback, :description, :value_pattern, :value_processor

			def initialize(&setup)
				@update_callback = ->(t,v){t + v}
				@value_processor = ->(v){v}
				instance_eval &setup
			end

			def update(&callback)
				@update_callback = callback
			end

			def report(description, value_pattern, &value_processor)
				@description = description
				@value_pattern = value_pattern
				@value_processor = value_processor if value_processor
			end
		end

		def initialize(init_value, &setup)
			@dsl = DSL.new(&setup)
			@value = init_value
		end

		def update(value)
			@value = @dsl.update_callback.call(@value, value)
		end

		def value
			@dsl.value_pattern % [@dsl.value_processor.call(@value)]
		end

		def description
			@dsl.description
		end

		def to_s
			"#{description}: #{value.rjust(6)}"
		end

		def final
			"#{description}: ".ljust(40) + value
		end
	end

	def initialize(queue_size, &callback)
		@report_queue = SizedQueue.new(queue_size)
		@processor = callback

		on_finish do
			# flush thread waiting on queue
			@report_queue.max = 999999
		end
	end

	def run
		super do
			@processor.call(self) if @processor
			until (report = @report_queue.pop) == :end
				@sink.call(*report) if @sink
			end
		end
	end

	def each(&callback)
		@sink = callback
	end

	def report(key, value)
		@report_queue << [key, value]
	end

	def time(key)
		time = Time.now.to_f
		yield
		report key, Time.now.to_f - time
	end

	def join
		@report_queue << :end
		super
	end
end

class BucketProcessor
	def initialize(key_id, key_secret, bucket, options = {}, &callback)
		protocol = options[:no_https] ? 'http' : 'https'
		port = options[:no_https] ? 80 : 443
		@log = options[:log] || Logger.new(STDERR)
		workers = options[:workers] || 10
		lister_fetch_size = options[:lister_fetch_size] || 200
		lister_backlog = options[:lister_backlog] || 1000
		max_keys = options[:max_keys]
	 	reporter_backlog = options[:reporter_backlog] || 1000
		reporter_summary_interval = options[:reporter_summary_interval] || 100
		reporter_average_contribution = options[:reporter_average_contribution] || 0.10
		custom_reports = options[:reports] || []
		@key_list = options[:key_list]

		s3 = RightAws::S3.new(key_id, key_secret, multi_thread: true, logger: @log, protocol: protocol, port: port)
		bucket = s3.bucket(bucket)

		@key_queue = SizedQueue.new(lister_backlog)

		@reporter = Reporter.new(reporter_backlog) do |reports|
			total_listed_keys = 0
			total_processed_keys = 0
			total_succeeded_keys = 0
			total_failed_keys = 0
			total_handled_keys = 0
			total_skipped_keys = 0
			total_nooped_keys = 0

			processed_avg = 0.0
			last_time = nil
			last_total = 0

			reports.each do |key, value|
				case key
				when :new_keys_count
					total_listed_keys += value
				when :processed_key
					total_processed_keys += 1
					if total_processed_keys % reporter_summary_interval == 0
						if last_time
							contribution = reporter_average_contribution
							new = (total_processed_keys - last_total).to_f / (Time.now.to_f - last_time)
							processed_avg = processed_avg * (1.0 - contribution) + new * contribution
						end
						last_time = Time.now.to_f
						last_total = total_processed_keys

						log_line = "-[%s]- processed %6d: failed: %6d (%6.2f %%) handled: %6d skipped: %6d (%6.2f %%)" % [
							value.to_s[0...2].ljust(2),
							total_processed_keys,
							total_failed_keys,
							total_failed_keys.to_f / total_processed_keys * 100,
							total_handled_keys,
							total_skipped_keys,
							total_skipped_keys.to_f / total_processed_keys * 100
						]
						log_line << custom_reports.each_value.map{|v| ' ' + v.to_s}.join
						log_line << " [backlog: %4d] @ %.1f op/s" % [
							@key_queue.size,
							processed_avg
						]

						@log.info log_line
					end
				when :succeeded_key
					total_succeeded_keys += 1
				when :failed_key
					key, error = *value
					@log.error "Key processing failed: #{key}: #{error.class.name}, #{error.message}"
					total_failed_keys += 1
				when :handled_key
					total_handled_keys += 1
				when :skipped_key
					total_skipped_keys += 1
				when :noop_key
					total_nooped_keys += 1
				else
					#@log.debug "custom report event: #{key}: #{value}"
					custom_reports[key].update(value)
				end
				#@log.debug("Report: #{key}: #{value}")
			end

			reports.on_finish do
				@log.info("total listed keys:                      #{total_listed_keys}")
				@log.info("total processed keys:                   #{total_processed_keys}")
				@log.info("total succeeded keys:                   #{total_succeeded_keys}")
				@log.info("total failed keys:                      #{total_failed_keys}")
				@log.info("total handled keys:                     #{total_handled_keys}")
				@log.info("total skipped keys:                     #{total_skipped_keys}")
				@log.info("total nooped keys:                      #{total_nooped_keys}")
				custom_reports.each_value do |report|
					@log.info report.final
				end
			end
		end

		# create lister
		@lister = if @key_list
			@log.info "processing #{@key_list.length} keys from list file"
			@lister = ListLister.new(bucket, @key_queue, max_keys)
		else
			@lister = Lister.new(bucket, @key_queue, lister_fetch_size, max_keys)
		end
		.on_keys_chunk do |keys_chunk|
			@log.debug "Got #{keys_chunk.length} new keys"
			@reporter.report(:new_keys_count, keys_chunk.length)
		end
		.on_finish do
			@log.debug "Done listing keys"
			# notify all workers that no more messages will be posted
			workers.times{ @key_queue << :end }
		end

		# create workers
		@log.info "Launching #{workers} workers"
		@workers = (1..workers).to_a.map do |worker_no|
			Worker.new(worker_no, @key_queue) do |key|
				@log.debug "Worker[#{worker_no}]: Processing key #{key}"
				yield bucket, key, @reporter
				@reporter.report :processed_key, key
				@reporter.report :succeeded_key, key
			end
			.on_error do |key, error|
				@reporter.report :processed_key, key
				@reporter.report :failed_key, [key, error]
			end
			.on_finish do
				@log.debug "Worker #{worker_no} done"
			end
		end
	end

	def run(prefix = nil)
		begin
			@reporter.run
			if @key_list
				@lister.run(@key_list)
			else
				@lister.run(prefix)
			end
			@workers.each(&:run)

			# wait for all to finish
			@workers.each(&:join)
			@log.info "All workers done"

			@lister.join
			@reporter.join
		rescue Interrupt => error
			@log.warn 'Interrupted'
			# flush thread waiting on queues
			@key_queue.max = 999999
			@reporter.join
		end
	end
end
