#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates spec/fixtures/llm_performance_demo.json — synthetic traffic for
# `JO_DEMO=1 bin/llm_performance` (or `bin/llm_performance --demo`).
#
# Rows use offset_seconds relative to "now" so the demo always falls inside
# the report's default time ranges.

require "json"
require "pathname"

OUT = Pathname(__dir__).join("llm_performance_demo.json")

MODELS = [
  {
    "name" => "inclusionai/ling-3.0-flash",
    "ttft_base" => 1200,
    "ttft_jitter" => 400,
    "duration_extra" => 2500,
    "tps_base" => 45,
    "efforts" => [
      { "thinking" => { "type" => "adaptive" } },
      { "thinking" => { "type" => "enabled", "budget_tokens" => 1024 } },
      { "thinking" => { "type" => "disabled" } }
    ]
  },
  {
    "name" => "openai/gpt-oss-120b",
    "ttft_base" => 2800,
    "ttft_jitter" => 900,
    "duration_extra" => 5000,
    "tps_base" => 28,
    "efforts" => [
      { "thinking" => { "type" => "adaptive" } },
      { "reasoning_effort" => "high" },
      { "reasoning_effort" => "medium" }
    ]
  },
  {
    "name" => "anthropic/claude-sonnet-4",
    "ttft_base" => 900,
    "ttft_jitter" => 300,
    "duration_extra" => 3200,
    "tps_base" => 62,
    "efforts" => [
      { "thinking" => { "type" => "enabled", "budget_tokens" => 2048 } },
      { "thinking" => { "type" => "enabled", "budget_tokens" => 8192 } },
      {}
    ]
  }
].freeze

# Deterministic "random" so regenerating the fixture is stable.
seed = 42
rng = Random.new(seed)

rows = []

# ~6 hours of traffic, one row every ~4 minutes, cycling models.
(0...90).each do |i|
  offset = -((90 - i) * 240) # newest near now, oldest ~6h ago
  model = MODELS[i % MODELS.size]
  effort = model["efforts"][i % model["efforts"].size]

  ttft = model["ttft_base"] + rng.rand(-model["ttft_jitter"]..model["ttft_jitter"])
  ttft = [ttft, 80].max
  # Occasional slow TTFT spikes (e.g. 4.06s) for chart interest.
  ttft = 4060 + rng.rand(0..200) if (i % 17).zero?
  duration = ttft + model["duration_extra"] + rng.rand(-400..800)
  duration = [duration, ttft + 200].max

  output_tokens = (model["tps_base"] * ((duration - ttft) / 1000.0) * (0.85 + rng.rand * 0.3)).round
  output_tokens = [output_tokens, 8].max
  input_tokens = 800 + rng.rand(0..12_000)
  cache_read = (i % 3).zero? ? rng.rand(0..[input_tokens / 2, 1].max) : 0
  cache_creation = (i % 5).zero? ? rng.rand(0..400) : 0
  thinking_tokens = effort.dig("thinking", "type") == "disabled" || effort.empty? ? 0 : rng.rand(10..180)

  status = 200
  error = nil
  retries = 0

  # Sprinkle errors and retries.
  case i % 23
  when 0
    status = 429
    error = "Too many requests"
    ttft = nil
    output_tokens = 0
    thinking_tokens = 0
  when 11
    status = 502
    error = "Connection reset by peer"
    retries = 1
    ttft = nil
    output_tokens = 0
    thinking_tokens = 0
  when 19
    retries = 1
  end

  req_body = {
    "model" => model["name"],
    "messages" => [{ "role" => "user", "content" => "demo prompt #{i}" }],
    "max_tokens" => 1024
  }.merge(effort)

  resp_body =
    if status == 200
      {
        "id" => "demo-msg-#{i}",
        "type" => "message",
        "role" => "assistant",
        "model" => model["name"],
        "content" => [{ "type" => "text", "text" => "demo reply #{i}" }],
        "usage" => {
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "cache_read_input_tokens" => cache_read,
          "cache_creation_input_tokens" => cache_creation,
          "output_tokens_details" => { "thinking_tokens" => thinking_tokens }
        }
      }
    else
      { "error" => { "message" => error } }
    end

  rows << {
    "offset_seconds" => offset,
    "status" => status,
    "ttft_ms" => ttft,
    "duration_ms" => duration,
    "retry_count" => retries,
    "error" => error,
    "body" => resp_body,
    "req_body" => req_body
  }
end

payload = {
  "description" => "Synthetic LLM performance rows for demo mode. offset_seconds is relative to now when loaded.",
  "generated_by" => "spec/fixtures/generate_llm_performance_demo.rb",
  "seed" => seed,
  "rows" => rows
}

OUT.write(JSON.pretty_generate(payload))
puts "Wrote #{rows.size} rows → #{OUT}"
