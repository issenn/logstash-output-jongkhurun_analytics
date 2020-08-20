# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/outputs/jongkhurun_analytics"
require "logstash/codecs/plain"
require "logstash/event"
require "base64"

PORT = rand(65535 - 1024) + 1025

describe LogStash::Outputs::JongkhurunAnalytics do
  let(:sample_event) { LogStash::Event.new }
  let(:output) { LogStash::Outputs::JongkhurunAnalytics.new }

  before do
    output.register
  end

  describe "receive message" do
    subject { output.receive(sample_event) }

    it "returns a string" do
      expect(subject).to eq("Event received")
    end
  end
end
