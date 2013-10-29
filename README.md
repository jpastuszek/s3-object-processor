# s3-object-processor

This library tries to help in development of CLI programs that can process all objects (or from list file) stored in given S3 bucket.

It is using multi-threaded worker model to allow for processing parallelism.

# Example usage

This example program can be used to call one of two HTTP endpoints for each object that matches a regexp and some other criteria.
In addition total handled objects size is counted and time spent on getting S3 object data and spend on API call is measured and reported at the end of the run.

```ruby
require 's3-object-processor/cli'
require 'httpclient'

S3ObjectProcessor::CLI.new do
	cli do
		option :endpoint,
			description: 'API endpoint URI for JPEG uploads',
			default: '/iss/v2/pictures'
		option :endpoint_as_is,
			description: 'API endpoint URI for as-is uploads',
			default: '/iss/v2/images'
		switch :as_is,
			description: 'upload images without conversion to JPEG'
		option :httpimagestore,
			description: 'URL to HTTP Image Store',
			default: 'http://localhost:3000'
	end

	cli_process do |settings|
	end

	report :input_object_size, 0 do
		report "total input object size [KiB]", "%d" do |value|
			(value.to_f / 1024).round
		end
	end
	report :s3_body_get_time, 0.0 do
		report "total S3 get body time [s]", "%.3f"
	end
	report :httpimagestore_time, 0.0 do
		report "total ISS request time [s]", "%.3f"
	end

	processor do |bucket, key, settings, log, reporter|
		unless key.to_s =~ %r{(^|.*?/)([0-f]{16})(|/.*)\.(.{3,4})$}
			log.warn "skipping bad format: #{key}"
			reporter.report :skipped_key, key
			next
		end

		dir = $1
		hash = $2
		name = $3
		extension = $4

		if name =~ /-(search|original|search_thumb|brochure|brochure_thumb|admin|admin_thumb|treatment_thumb|staff_member_thumb|consultation|clinic_google_map_thumb)$/
			log.debug "skipping not original: #{key}"
			reporter.report :skipped_key, key
			next
		end

		log.debug "processing original dir: '#{dir}' hash: '#{hash}' name: '#{name}' extension: '#{extension}'"

		data = nil
		reporter.time :s3_body_get_time do
			data = key.data
		end
		fail "no data for key; key not found?!" unless data
		reporter.report :input_object_size, data.length

		if settings.noop
			reporter.report :noop_key, key
			next
		end

		reporter.time :httpimagestore_time do
			if settings.as_is
				response = HTTPClient.put(settings.httpimagestore + settings.endpoint_as_is + "/#{hash}.#{extension}", data)
			else
				response = HTTPClient.put(settings.httpimagestore + settings.endpoint + "/#{hash}.jpg", data)
			end
			fail "bad HTTP Image Store response: #{response.status}: #{response.body}" if response.status != 200
		end
		reporter.report :handled_key, key
	end
end
```

## Contributing to s3-object-processor

* Check out the latest master to make sure the feature hasn't been implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

## Copyright

Copyright (c) 2013 Jakub Pastuszek. See LICENSE.txt for
further details.

