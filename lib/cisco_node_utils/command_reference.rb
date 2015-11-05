# CommandReference module for testing.
#
# Copyright (c) 2014-2015 Cisco and/or its affiliates.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'yaml'

module Cisco
  # Control a reference for an attribute.
  class CmdRef
    attr_reader :feature
    attr_reader :name
    attr_reader :hash

    KEYS = %w(default_value
              config_set config_set_append
              config_get config_get_token config_get_token_append
              test_config_get test_config_get_regex test_config_result)

    def self.keys
      KEYS
    end

    # Construct a CmdRef describing the given (feature, name) pair.
    # Param "values" is a hash with keys as described in KEYS.
    # Param "file" is for debugging purposes only.
    def initialize(feature, name, values, file)
      fail ArgumentError, "'#{values}' is not a hash." unless values.is_a? Hash

      @feature = feature
      @name = name
      @hash = {}

      values.each do |key, value|
        unless KEYS.include?(key)
          fail "Unrecognized key #{key} for #{feature}, #{name} in #{file}"
        end
        if value.nil?
          # Some attributes can store an explicit nil.
          # Others treat this as unset (allowing a platform to override common).
          @hash[key] = value if key == 'default_value'
          next
        elsif key == 'config_get_token' || key == 'config_set'
          # For simplicity, these are ALWAYS arrays
          value = [value] unless value.is_a?(Array)
          define_getter(key, value)
        end
        # We intentionally do this *after* the define_getter() call above.
        @hash[key] = preprocess_value(value)
      end
    end

    # Create a getter method for the given key.
    # This getter method will automatically handle wildcard arguments.
    def define_getter(key, value)
      return unless value.is_a?(Array)
      if value.any? { |item| item.is_a?(String) && /<\S+>/ =~ item }
        # Key-value substitution
        define_singleton_method key.to_sym do |**args|
          result = []
          value.each do |line|
            replace = line.scan(/<(\S+)>/).flatten.map(&:to_sym)
            replace.each do |item|
              line = line.sub("<#{item}>", args[item].to_s) if args.key?(item)
            end
            result.push(line) unless /<\S+>/.match(line)
          end
          preprocess_value(result)
        end
      elsif value.any? { |item| item.is_a?(String) && /%/ =~ item }
        # printf-style substitution
        arg_count = value.join.scan(/%/).length
        define_singleton_method key.to_sym do |*args|
          unless args.length == arg_count
            fail ArgumentError, "Given #{args.length} args, but " \
              "#{key} requires #{arg_count}"
          end
          # Fill in the parameters
          result = value.map do |line|
            sprintf(line, *args.shift(line.scan(/%/).length))
          end
          preprocess_value(result)
        end
      else
        # simple static token(s)
        value = preprocess_value(value)
        define_singleton_method key.to_sym, -> { value }
      end
    end

    # Helper method.
    # Converts a regexp-like string (or array thereof) into a proper
    # Regexp object (or array thereof)
    def preprocess_value(value)
      if value.is_a?(Array)
        # Recurse!
        return value.map { |item| preprocess_value(item) }
      elsif value.is_a?(String)
        # Some 'Strings' in YAML are actually intended to be regexps
        if value[0] == '/' && value[-1] == '/'
          # '/foo/' => %r{foo}
          return Regexp.new(value[1..-2])
        elsif value[0] == '/' && value[-2..-1] == '/i'
          # '/foo/i' => %r{foo}i
          return Regexp.new(value[1..-3], Regexp::IGNORECASE)
        end
      end
      value
    end

    def convert_to_constant(value)
      # NOTE: This method is now deprecated and should not be used for future
      #       development.
      #
      # If value is a string and it is empty OR the first letter is lower case
      # then leave value untouched.
      # If value is a string and the first letter is uppercase this indicates
      # that it could be a constant in Ruby, so attempt to convert it
      # to a Constant.
      if value.is_a?(String) && !value.empty?
        if value[0].chr == value[0].chr.upcase
          begin
            value = Object.const_get(value) if Object.const_defined?(value)
          rescue NameError
            debug("'#{value}' is not a constant")
          end
        end
      end
      value
    end

    def test_config_result(value)
      result = @hash['test_config_result'][value]
      convert_to_constant(result)
    end

    def method_missing(method_name, *args, &block)
      if KEYS.include?(method_name.to_s)
        # ref.foo -> return @hash[foo] or fail IndexError
        method_name = method_name.to_s
        unless @hash.include?(method_name)
          fail IndexError, "No #{method_name} defined for #{@feature}, #{@name}"
        end
        # puts("get #{method_name}: '#{@hash[method_name]}'")
        @hash[method_name]
      elsif method_name.to_s[-1] == '?' && \
            KEYS.include?(method_name.to_s[0..-2])
        # ref.foo? -> return true if @hash[foo], else false
        method_name = method_name.to_s[0..-2]
        @hash[method_name].nil? ? false : true
      else
        super(method_name, *args, &block)
      end
    end

    # Print useful debugging information about the object.
    def to_s
      str = ''
      str << "Command: #{@feature} #{@name}\n"
      @hash.each { |key, value| str << "  #{key}: #{value}\n" }
      str
    end

    # Check that all necessary values have been populated.
    def valid?
      return false unless @feature && @name
      true
    end
  end

  # Builds reference hash for the platform specified in the product id.
  class CommandReference
    @@debug = false # rubocop:disable Style/ClassVars

    def self.debug=(value)
      fail ArgumentError, 'Debug must be boolean' unless value == true ||
                                                         value == false
      @@debug = value # rubocop:disable Style/ClassVars
    end

    attr_reader :cli, :files, :platform, :product_id

    # Constructor.
    # Normal usage is to pass product_id only, in which case all usual YAML
    # files will be located then the list will be filtered down to only those
    # matching the given product_id.
    # For testing purposes (only!) you can pass an explicit list of files to
    # load instead. This list will NOT be filtered further by product_id.
    def initialize(product:  nil,
                   platform: nil,
                   cli:      false,
                   files:    nil)
      @product_id = product
      @platform = platform
      @cli = cli
      @hash = {}
      if files
        @files = files
      else
        @files = Dir.glob(__dir__ + '/cmd_ref/*.yaml')
      end

      build_cmd_ref
    end

    # Build complete reference hash.
    def build_cmd_ref
      # Example id's: N3K-C3048TP-1GE, N3K-C3064PQ-10GE, N7K-C7009, N7K-C7009
      debug "Product: #{@product_id}"
      debug "Files being used: #{@files.join(', ')}"

      @files.each do |file|
        feature = File.basename(file).split('.')[0]
        debug "Processing file '#{file}' as feature '#{feature}'"
        feature_hash = load_yaml(file)

        base_hash = {}
        if feature_hash.key?('_template')
          base_hash = hash_merge(feature_hash['_template'])
        end

        feature_hash.each do |name, value|
          fail "No entries under '#{name}' in '#{file}'" if value.nil?
          @hash[feature] ||= {}
          values = hash_merge(value, base_hash.clone)
          @hash[feature][name] = CmdRef.new(feature, name, values, file)
        end
      end

      fail 'Missing values in CommandReference.' unless valid?
    end

    # Get the command reference
    def lookup(feature, name)
      begin
        value = @hash[feature][name]
      rescue NoMethodError
        # happens if @hash[feature] doesn't exist
        value = nil
      end
      fail IndexError, "No CmdRef defined for #{feature}, #{name}" if value.nil?
      value
    end

    def empty?
      @hash.empty?
    end

    # Print debug statements
    def debug(text)
      puts "DEBUG: #{text}" if @@debug
    end

    KNOWN_FILTERS = %w(cli_nexus cli_ios_xr)

    # Helper method
    # Given a Hash of command reference data (as read from YAML), does:
    # - Filter any API-specific data
    # - Filter any platform-specific data
    # - Inherit data from the given base_hash (if any) and extend/override it
    #   with the given input data.
    # - Append 'config_set_append' data to any existing 'config_set' data
    # - Append 'config_get_token_append' data to 'config_get_token', ditto
    def hash_merge(input_hash, base_hash=nil)
      return base_hash if input_hash.nil?

      result = base_hash
      result ||= {}
      # to_inspect: sub-hashes we want to recurse into
      to_inspect = []
      # regexp_match: did we find a product_id regexp that matches?
      regexp_match = false

      input_hash.each do |key, value|
        if CmdRef.keys.include?(key)
          if key == 'config_set_append'
            result['config_set'] = value_append(result['config_set'], value)
          elsif key == 'config_get_token_append'
            result['config_get_token'] = value_append(
              result['config_get_token'], value)
          else
            result[key] = value
          end
        elsif key[0] == '/'
          # it's a product-id regexp. Does it match our given product_id?
          next unless Regexp.new(key[1..-2]) =~ product_id
          regexp_match = true
          # Platform match - we want to descend into this sub-hash
          to_inspect << value
        elsif KNOWN_FILTERS.include?(key)
          next if key.match(/cli/) && !cli
          next unless key.match(platform.to_s)
          # API match - we want to descend into this sub-hash
          to_inspect << value
        elsif key == 'else'
          # Skip for now, we revisit it below
          next
        else
          fail "Unrecognized key '#{key}'"
        end
      end
      # If we didn't find any platform regexp match,
      # and an 'else' sub-hash is provided, descend into 'else'
      if input_hash.key?('else') && !regexp_match
        to_inspect << input_hash['else']
      end
      # Recurse! Sub-hashes can override the base hash
      to_inspect.each do |hash|
        result = hash_merge(hash, result)
      end
      result
    end

    # Helper method.
    # Combines the two given values (either or both of which may be arrays)
    # into a single combined array
    # value_append('foo', 'bar') ==> ['foo', 'bar']
    # value_append('foo', ['bar', 'baz']) ==> ['foo', 'bar', 'baz']
    def value_append(base_value, new_value)
      base_value = [base_value] unless base_value.is_a?(Array)
      new_value = [new_value] unless new_value.is_a?(Array)
      base_value + new_value
    end
    private :value_append

    def mapping?(node)
      node.class.ancestors.any? { |name| /Map/ =~ name.to_s }
    end
    private :mapping?

    def get_keys_values_from_map(node)
      # A Psych::Node::Mapping instance has an Array of children in
      # the format [key1, val1, key2, val2]
      key_children = node.children.select.each_with_index { |_, i| i.even? }
      val_children = node.children.select.each_with_index { |_, i| i.odd? }
      debug "children of #{node} mapping: #{key_children}, #{val_children}"
      [key_children, val_children]
    end
    private :get_keys_values_from_map

    # Validate the YAML node tree before converting it into Ruby
    # data structures.
    #
    # @raise RuntimeError if the node tree is not valid by our constraints.
    #
    # @param node Node to be validated, then recurse to its children.
    # @param filename File that YAML was parsed from, for messages
    # @param depth Depth into the node tree
    # @param parents String describing parents of this node, for messages
    def validate_yaml(node, filename, depth=0, parents=nil)
      return unless node && (mapping?(node) || node.children)
      # Psych wraps everything in a Document instance, which we ignore.
      unless node.class.ancestors.any? { |name| /Document/ =~ name.to_s }
        depth += 1
      end
      debug "Validating #{node.class} at depth #{depth}"

      # No special validation for non-mapping nodes - just recurse
      unless mapping?(node)
        node.children.each do |child|
          validate_yaml(child, filename, depth, parents)
        end
        return
      end

      # For Mappings, we validate more extensively:
      # 1. no duplicate keys are allowed (Psych doesn't catch this)
      # 2. Features must be listed in alphabetical order for maintainability

      # Take advantage of our known YAML structure to assign labels by depth
      label = %w(feature name param).fetch(depth, 'key')

      # Get the key nodes and value nodes under this mapping
      key_children, val_children = get_keys_values_from_map(node)
      # Get an array of key names
      key_arr = key_children.map(&:value)

      # Make sure no duplicate key names.
      # If searching from the start of the array finds a name at one index,
      # but searching from the end of the array finds it at a different one,
      # then we have a duplicate.
      dup = key_arr.detect { |e| key_arr.index(e) != key_arr.rindex(e) }
      if dup
        msg = "Duplicate #{label} '#{dup}'#{parents} in #{filename}!"
        fail msg
      end

      # Enforce alphabetical ordering of features (only).
      # We can extend this later to enforce ordering of names if desired
      # by checking at depth 2 as well.
      if depth == 1
        last_key = nil
        key_arr.each do |key|
          if last_key && key < last_key
            fail "features out of order in #{filename}: (#{last_key} > #{key})"
          end
          last_key = key
        end
      end

      # Recurse to the children. We get a little fancy here so as to be able
      # to provide more meaningful debug/error messages, such as:
      # Duplicate param 'default_value' under feature 'foo', name 'bar'
      key_children.zip(val_children).each do |key_node, val_node|
        if parents
          new_parents = parents + ", #{label} '#{key_node.value}'"
        else
          new_parents = " under #{label} '#{key_node.value}'"
        end
        validate_yaml(key_node, filename, depth, new_parents) # unnecessary?
        validate_yaml(val_node, filename, depth, new_parents)
      end
    end
    private :validate_yaml

    # Read in yaml file.
    # The expectation is that a file corresponds to a feature
    def load_yaml(yaml_file)
      fail "File #{yaml_file} doesn't exist." unless File.exist?(yaml_file)
      # Parse YAML file into a tree of nodes
      # Psych::SyntaxError doesn't inherit from StandardError in some versions,
      # so we want to explicitly catch it if using Psych.
      rescue_errors = [::StandardError, ::Psych::SyntaxError]
      yaml_parsed = File.open(yaml_file, 'r') do |f|
        begin
          YAML.parse(f)
        rescue *rescue_errors => e
          raise "unable to parse #{yaml_file}: #{e}"
        end
      end
      return {} unless yaml_parsed
      # Validate the node tree
      validate_yaml(yaml_parsed, yaml_file)
      # If validation passed, convert the node tree to a Ruby Hash.
      yaml_parsed.transform
    end

    # Check that all resources were pulled in correctly.
    def valid?
      complete_status = true
      @hash.each_value do |names|
        names.each_value do |ref|
          status = ref.valid?
          debug('Reference does not contain all supported values:' \
                "\n#{ref}") unless status
          complete_status = (status && complete_status)
        end
      end
      complete_status
    end

    def to_s
      @hash.each_value { |names| names.each_value(&:to_s) }
    end
  end
end
