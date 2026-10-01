# frozen_string_literal: true

require_relative 'compiled_template_roundtrip_helper'

payload_path = ARGV.fetch(0)
payload = File.read(payload_path)
environment = CompiledTemplateRoundtripHelper.environment
template = Liquid::Template.load_compiled(payload, environment: environment)
print(JSON.generate(CompiledTemplateRoundtripHelper.results(template)))
