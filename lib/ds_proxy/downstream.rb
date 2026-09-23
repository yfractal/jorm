# frozen_string_literal: true

require "json"

module DsProxy
  # Owns patching of an incoming request body before it's forwarded
  # upstream: rewrites the body in place when it matches the security
  # classifier.
  class Downstream
    def initialize(req)
      @req = req
    end

    # Returns [body, patched] - the (possibly rewritten) body and whether
    # it was patched.
    def patch
      body = @req.body
      content_type = @req.content_type
      patched = false

      if !body.empty? && content_type.include?("application/json")
        begin
          parsed = JSON.parse(body)
          if SecurityClassifier.match?(parsed)
            SecurityClassifier.patch!(parsed)
            body = JSON.generate(parsed)
            patched = true
          end
        rescue JSON::ParserError
          # keep original request on parse failure
        end
      end

      [body, patched]
    end
  end
end
