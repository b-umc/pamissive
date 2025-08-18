# frozen_string_literal: true

class EventBus
  @instance = nil
  class << self
    def instance
      @instance ||= new
    end

    def subscribe(...)
      instance.subscribe(...)
    end

    def unsubscribe(...)
      instance.unsubscribe(...)
    end

    def publish(...)
      instance.publish(...)
    end
  end

  private_class_method :new

  def initialize
    @subscribers = {} # Hash.new { |h, k| h[k] = [] }
  end

  def subscribe(event_path, event_name, prc)
    key = build_key(event_path, event_name)
    LOG.debug([:new_subscription, key, prc])
    @subscribers[key] ||= []
    @subscribers[key] << prc
  end

  def unsubscribe(event_path, event_name, prc)
    key = build_key(event_path, event_name)
    LOG.debug([:unsubscribing, key, prc, @subscribers[key].length])
    @subscribers[key].delete(prc)
  end

  def publish(event_path, event_name, *args)
    LOG.debug([:event_published, event_path, event_name, args])
    key = build_key(event_path, event_name)
    notify_subscribers(key, args)
  end

  private

  def build_key(path, name)
    "#{path}:#{name}"
  end

  def notify_subscribers(key, args)
    LOG.debug([:notifying, key, :count, @subscribers[key]&.length])
    @subscribers[key]&.each { |handler| handler.call(args) }
    # Notify wildcard subscribers
    wildcard_key = "#{key.split(':').first}:*"
    @subscribers[wildcard_key]&.each { |handler| handler.call(args) unless key == wildcard_key }
  end
end
