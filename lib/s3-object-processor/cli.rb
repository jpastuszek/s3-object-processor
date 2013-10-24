require 's3-object-processor'
require 'cli'
require 'logger'
require 'right_aws'
require 'time'

module S3ObjectProcessor
	class CLI
		def initialize(&config)
			@reports = {}
			instance_eval &config

			cli_setup = @cli_setup
			cli_process_setup = @cli_process_setup

			settings = ::CLI.new do
				description 'Set header of S3 object'

				option :key_id,
					short: :i,
					description: 'AWS access key ID',
					default_label: 'AWS_SECRET_KEY_ID environment variable',
					default: ENV['AWS_ACCESS_KEY_ID'],
					required: true
				option :key_secret,
					short: :s,
					description: 'AWS access key secret',
					default_label: 'AWS_SECRET_ACCESS_KEY environment variable',
					default: ENV['AWS_SECRET_ACCESS_KEY'],
					required: true
				switch :no_https,
					description: 'use plain HTTP S3 connections'

				option :bucket,
					short: :b,
					description: 'bucket to process',
					required: true
				option :prefix,
					short: :p,
					description: 'process only objects of key starting with given prefix'

				option :lister_fetch_size,
					description: 'fetch no more that that number of keys per request',
					cast: Integer,
					default: 200
				option :lister_backlog,
					description: 'maximum length of to be processed key queue',
					cast: Integer,
					default: 1000

				option :reporter_backlog,
					description: 'maximum length of to be processed report queue',
					cast: Integer,
					default: 1000
				option :reporter_summary_interval,
					description: 'pring summary every some number of processed objects',
					cast: Integer,
					default: 100
				option :reporter_average_contribution,
					description: 'how much does last average calculation contribute in the printed value - less => more stable',
					cast: Float,
					default: 0.10

				option :workers,
					short: :t,
					description: 'number of processing threads to start',
					cast: Integer,
					default: 10

				switch :noop,
					short: :n,
					description: 'do not change any object; just say what would be done'

				switch :debug,
					short: :d,
					description: 'log at DEBUG level'

				option :max_keys,
					description: 'stop after processing this amout of keys',
					cast: Integer

				instance_eval &cli_setup if cli_setup
			end.parse! do |settings|
				instance_eval &cli_process_setup if cli_process_setup
			end

			log = Logger.new(STDERR)
			log.level = settings.debug ? Logger::DEBUG : Logger::INFO

			log.debug(settings.inspect)

			BucketProcessor.new(settings.key_id, settings.key_secret, settings.bucket,
				no_https: settings.no_https,
				log: log,
				workers: settings.workers,
				max_keys: settings.max_keys,
				lister_fetch_size: settings.lister_fetch_size,
				lister_backlog: settings.lister_backlog,
				reporter_backlog: settings.reporter_backlog,
				reporter_summary_interval: settings.reporter_summary_interval,
				reporter_average_contribution: settings.reporter_average_contribution,
				reports: @reports
			) do |bucket, key, reporter|
				@processor.call(bucket, key, settings, log, reporter)
			end
			.run(settings.prefix)
		end

		def cli(&setup)
			@cli_setup = setup
		end

		def cli_process(&setup)
			@cli_process_setup = setup
		end

		def report(name, init_value, &setup)
			@reports[name] = Reporter::Report.new(init_value, &setup)
		end

		def processor(&callback)
			@processor = callback
		end
	end
end
