require 'forwardable'

require 'ddtrace/ext/priority'

module Datadog
  # \Sampler performs client-side trace sampling.
  class Sampler
    def sample?(_span)
      raise NotImplementedError, 'Samplers must implement the #sample? method'
    end

    def sample!(_span)
      raise NotImplementedError, 'Samplers must implement the #sample! method'
    end
  end

  # \AllSampler samples all the traces.
  class AllSampler < Sampler
    def sample?(span)
      true
    end

    def sample!(span)
      span.sampled = true
    end
  end

  # \RateSampler is based on a sample rate.
  class RateSampler < Sampler
    KNUTH_FACTOR = 1111111111111111111
    SAMPLE_RATE_METRIC_KEY = '_sample_rate'.freeze

    attr_reader :sample_rate

    # Initialize a \RateSampler.
    # This sampler keeps a random subset of the traces. Its main purpose is to
    # reduce the instrumentation footprint.
    #
    # * +sample_rate+: the sample rate as a \Float between 0.0 and 1.0. 0.0
    #   means that no trace will be sampled; 1.0 means that all traces will be
    #   sampled.
    def initialize(sample_rate = 1.0)
      unless sample_rate > 0.0 && sample_rate <= 1.0
        Datadog::Tracer.log.error('sample rate is not between 0 and 1, disabling the sampler')
        sample_rate = 1.0
      end

      self.sample_rate = sample_rate
    end

    def sample_rate=(sample_rate)
      @sample_rate = sample_rate
      @sampling_id_threshold = sample_rate * Span::MAX_ID
    end

    def sample?(span)
      ((span.trace_id * KNUTH_FACTOR) % Datadog::Span::MAX_ID) <= @sampling_id_threshold
    end

    def sample!(span)
      (span.sampled = sample?(span)).tap do |sampled|
        span.set_metric(SAMPLE_RATE_METRIC_KEY, @sample_rate) if sampled
      end
    end
  end

  # \RateByServiceSampler samples different services at different rates
  class RateByServiceSampler < Sampler
    DEFAULT_KEY = 'service:,env:'.freeze

    def initialize(rate = 1.0, opts = {})
      @env = opts.fetch(:env, Datadog.tracer.tags[:env])
      @mutex = Mutex.new
      @fallback = RateSampler.new(rate)
      @sampler = { DEFAULT_KEY => @fallback }
    end

    def sample?(span)
      key = key_for(span)

      @mutex.synchronize do
        @sampler.fetch(key, @fallback).sample?(span)
      end
    end

    def sample!(span)
      key = key_for(span)

      @mutex.synchronize do
        @sampler.fetch(key, @fallback).sample!(span)
      end
    end

    def sample_rate(span)
      key = key_for(span)

      @mutex.synchronize do
        @sampler.fetch(key, @fallback).sample_rate
      end
    end

    def update(rate_by_service)
      @mutex.synchronize do
        @sampler.delete_if { |key, _| key != DEFAULT_KEY && !rate_by_service.key?(key) }

        rate_by_service.each do |key, rate|
          @sampler[key] ||= RateSampler.new(rate)
          @sampler[key].sample_rate = rate
        end
      end
    end

    private

    def key_for(span)
      "service:#{span.service},env:#{@env}"
    end
  end

  # \PrioritySampler
  class PrioritySampler
    extend Forwardable

    SAMPLE_RATE_METRIC_KEY = '_sample_rate'.freeze

    def initialize(opts = {})
      @pre_sampler = opts[:base_sampler] || AllSampler.new
      @priority_sampler = opts[:post_sampler] || RateByServiceSampler.new
    end

    def sample?(span)
      @pre_sampler.sample?(span)
    end

    def sample!(span)
      # If pre-sampling is configured, do it first. (By default, this will sample at 100%.)
      # NOTE: Pre-sampling at rates < 100% may result in partial traces; not recommended.
      span.sampled = pre_sample?(span) ? @pre_sampler.sample!(span) : true

      if span.sampled
        # If priority sampling has already been applied upstream, use that, otherwise...
        unless priority_assigned_upstream?(span)
          # Roll the dice and determine whether how we set the priority.
          # NOTE: We'll want to leave `span.sampled = true` here; all spans for priority sampling must
          #       be sent to the agent. Otherwise metrics for traces will not be accurate, since the
          #       agent will have an incomplete dataset.
          priority = priority_sample(span) ? Datadog::Ext::Priority::AUTO_KEEP : Datadog::Ext::Priority::AUTO_REJECT
          assign_priority!(span, priority)
        end
      else
        # If discarded by pre-sampling, set "reject" priority, so other
        # services for the same trace don't sample needlessly.
        assign_priority!(span, Datadog::Ext::Priority::AUTO_REJECT)
      end

      span.sampled
    end

    def_delegators :@priority_sampler, :update

    private

    def pre_sample?(span)
      case @pre_sampler
      when RateSampler
        @pre_sampler.sample_rate < 1.0
      when RateByServiceSampler
        @pre_sampler.sample_rate(span) < 1.0
      else
        true
      end
    end

    def priority_assigned_upstream?(span)
      span.context && !span.context.sampling_priority.nil?
    end

    def priority_sample(span)
      @priority_sampler.sample?(span)
    end

    def assign_priority!(span, priority)
      if span.context
        span.context.sampling_priority = priority
      end

      # Set the priority directly on the span instead, since otherwise
      # it won't receive the appropriate tag.
      span.set_metric(
        Ext::DistributedTracing::SAMPLING_PRIORITY_KEY,
        priority
      )
    end
  end
end
