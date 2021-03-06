require "plist"
require "nokogiri-plist"

module Fastlane
  # Alias for displaying UI messages.
  UI = UI unless Fastlane.const_defined?("UI")

  # Extension for Fastlane::Helper module.
  module Helper
    # Xcspec helper class.
    class Xcspec
      ###
      # @!group Mapping
      ###

      # Class for managing build flags mapping.
      class Mapping
        # Main tool flags.
        attr_reader :flags

        # Additional linker flags
        attr_reader :linker_flags

        # Initialize new mapping.
        # @param [String] flags Main tool flags.
        # @param [String] linker_flags Additional linker flags.
        def initialize(flags = "", linker_flags = "")
          @flags = flags
          @linker_flags = linker_flags
        end

        # Join with other mapping and return new mapping.
        # @param [Mapping] other Other mapping to join with.
        # @return [Mapping] New joined mapping.
        def join(other)
          return self if other.nil?

          joined_flags = [flags, other.flags].reject(&:empty?).join(" ")
          joined_linker_flags = [linker_flags, other.linker_flags].reject(&:empty?).join(" ")

          Mapping.new(joined_flags, joined_linker_flags)
        end
      end

      ###
      # @!group Initialization
      ###

      # Path to xcspec file.
      attr_reader :path

      # @return [Array<Hash>] Xcspec options.
      attr_reader :options

      # Create new instance.
      # @param [String] path Path to xcspec file.
      # @param [Xcspec] core_build_system_spec Core build system spec.
      def initialize(path, core_build_system_spec: nil)
        UI.user_error!("No such file: #{path}") unless path && File.exist?(path)

        @path = path

        plist = Xcspec.load_plist(path)
        tools = plist.kind_of?(Array) ? plist : [plist]

        @options = tools.flat_map { |t| t["Options"] || t["Properties"] }.compact
        @options += core_build_system_spec.options if core_build_system_spec
      end

      # Load plist as a dictionary.
      # @param [String] path Path to plist file.
      # @return [Hash] Plist dictionary.
      def self.load_plist(path)
        file_type = `file -b --mime-type #{path.shellescape}`.chomp
        if file_type == "text/xml" || file_type == "application/xml"
          xml_plist = path
        else
          if FastlaneCore::Helper.mac?
            xml_plist = Tempfile.new("xcspec.plist").path
            result = system("plutil -convert xml1 -o #{xml_plist.shellescape} #{path.shellescape}")
            UI.user_error!("Couldn't convert #{path} xcspec to XML plist") unless result
          else
            # There is plist-utils library, but it can only convert binary to XML, can't handle ASCII.
            UI.user_error!("Can't convert ASCII plists to XML on Linux or Windows platform")
          end
        end

        Nokogiri::PList(File.open(xml_plist))
      end

      ###
      # @!group Helpers
      ###

      # Find option by name.
      # @param [String] name Option name.
      # @return [Hash] Option or `nil`.
      def find_option(name)
        @options.find { |o| o["Name"] == name }
      end

      ###
      # @!group Mapping
      ###

      # Map build settings to build flags.
      # @param [Hash] build_settings Build settings.
      # @return [Hash] Build flags.
      def map_build_settings(build_settings)
        # Some settings like ENABLE_TESTABILITY are used as default value for other build settings,
        # e.g. SWIFT_ENABLE_TESTABILITY.
        # So need to treat dependant (implicit) build settings as if they were defined in xcconfig
        # in order to get them properly resolved.
        implicit_build_settings = @options.reduce({}) do |memo, opt|
          name = opt["Name"]
          next memo if build_settings.key?(name)
          reference = build_settings.find { |k, _| opt["DefaultValue"].eql?("$(#{k})") }
          reference ? memo.merge({ name => reference.last }) : memo
        end
        build_settings = build_settings.merge(implicit_build_settings)

        # Build settings provided for mapping will not include all possible build settings.
        # Add default values for missing build settings.
        missing_build_settings = @options.reduce({}) do |memo, opt|
          name = opt["Name"]
          build_settings.key?(name) ? memo : memo.merge({ name => opt["DefaultValue"] })
        end
        complete_build_settings = build_settings.merge(missing_build_settings)

        mappings = build_settings.flat_map do |setting, value|
          map_build_setting_value(setting, value, complete_build_settings)
        end.compact

        mappings.reduce(Mapping.new) { |memo, m| memo.join(m) }
      end

      # Map single build setting value.
      # @param [String] name Build setting name.
      # @param [String] value Build setting value.
      # @param [Hash] build_settings Dictionary of build settings to resolve the values against.
      # @return [Array<Mapping>] List of mappings for this build setting value.
      def map_build_setting_value(name, value, build_settings)
        option = find_option(name)
        return nil unless option

        map_option(option, value, build_settings)
      end

      # Map the spec option to build settings using the value.
      # @param [Hash] option Xcspec option describing build setting.
      # @param [String] value Build setting value.
      # @param [Hash] build_settings Dictionary of all build settings.
      # @return [Array<Mapping>] List of mappings.
      def map_option(option, value, build_settings)
        # Evaluate and check the 'Condition'.
        return nil unless check_condition(option, build_settings)

        # If type of the value is one of List types (StringList, PathList),
        # then split it into value list, else just use scalar value itself.
        scalar_values = option["Type"].downcase.end_with?("list") ? value.split : [value]
        scalar_values.flat_map { |v| map_option_scalar_value(option, v, build_settings) }.compact
      end

      # Map the spec option scalar value to build flags.
      # @param [Hash] option Xcspec option for build setting.
      # @param [String] value Scalar value of the build setting.
      # @param [Hash] build_settings Dictionary of all resolved build settings.
      # @return [Mapping] Mapping for the specified scalar value.
      def map_option_scalar_value(option, value, build_settings)
        # At this point we deal with scalar value.

        # Type = StringList
        #   - CommandLineFlag and CommandLinePrefixFlag - map each string in the list.
        #   - CommandLineArgs - map each string in the list.
        #   - Finally there are entries with only Category = CustomFlags.
        #     Those end up in compiler flags for sure, so looks like if category is CustomFlags,
        #     then should use them as is.
        #     There's only 3 of them: OTHER_CFLAGS, OTHER_CPLUSPLUSFLAGS and WARNING_CFLAGS.
        # PathList, that for all intents and purposes can be handed as StringList.

        # - CommandLineArgs
        #   - If input is StringList, then map each entry from string list according to CommandLineArgs value
        #     The value of CommandLineArgs can be an array, use flat map
        #     Can have a switch, e.g.
        #       CommandLineArgs = {
        #         "" = ();
        #         "<<otherwise>>" = (
        #            "-$(DEPLOYMENT_TARGET_CLANG_FLAG_NAME)=$(value)",
        #        );
        #       };
        #     All these switches, however, map to nothing for empty string and to something for non-empty string.
        #     The vey same switch is used for enums. Switching for enums vs string is no different,
        #     since switching happens on string values.
        #     <<otherwise>> is for other values
        # - AdditionalLinkerArgs
        #   Few build settings have them, collected separately, work just like CommandLineArgs for parsing.
        # - CommandLineFlag and CommandLinePrefixFlag
        #   - If input is StringList then applied to each entry in the list, to each entry applied as to a scalar value:
        #   - If input is scalar String value, then applied just once as -<flag> $(value)
        #   - If input is boolean, then just the flag is used, e.g. -<flag>, no Prefix option supported for boolean.
        #   - While for prefix it appears there's no space and it is -<prefix>$(value)
        #   - An exception(!) is MACH_O_TYPE, where no value is appended but just the flag is used.
        #     It is also the only enum where list of values has command line flag for each value.

        # Type = Enumeration
        #   Most of them have CommandLineArgs with a switch.
        #   Some also come with AdditionalLinkerArgs, which is mapped in similar way.
        #   Then there's MACH_O_TYPE, which has CommandLineFlag under Values...
        #   But only when used for linker flags:
        #     Value = "mh_dylib";
        #     CommandLineFlag = "-dynamiclib";
        #   -dynamiclib is a flag that doesn't take input, so only specified as is.

        flags = ""
        if (cli_args = option["CommandLineArgs"])
          flags = map_args(option, cli_args, value, build_settings)
        elsif (cli_flag = option["CommandLineFlag"])
          # If Boolean and YES, then use CommandLineFlag value.
          if option["Type"] == "Boolean"
            flags = cli_flag if value == "YES"
          else
            flags = [cli_flag, value].join(" ")
          end
        elsif (cli_prefix_flag = option["CommandLinePrefixFlag"])
          flags = [cli_prefix_flag, value].join # Join with no space in between.
        elsif option["Category"] == "CustomFlags"
          flags = value
        else
          # Nothing to map to, except for when it's MACH_O_TYPE, when it has list of dictionaries:
          # Values = ( { Value = "v", CommandLineFlag = "f", ... } )
          match = (option["Values"] || []).find { |v| v["Value"] == value } || {}
          flags = match["CommandLineFlag"] || ""
        end

        linker_flags = ""
        if (linker_args = option["AdditionalLinkerArgs"])
          linker_flags = map_args(option, linker_args, value, build_settings)
        end

        Mapping.new(flags, linker_flags)
      end

      # Map command line arguments to build flags.
      # @param [Hash] option Xcspec option for build setting.
      # @param [Array<String>] args List of arguments to map.
      # @param [String] value Value of the build setting.
      # @param [Hash] build_settings All build settings to use for mapping.
      # @return [String] Resolved value.
      def map_args(option, args, value, build_settings)
        return "" unless args

        if args.kind_of?(Hash)
          map_args(option, args[value] || args["<<otherwise>>"], value, build_settings)
        else
          # Args should be an array here, but can be just single string.

          resolved_args = args.kind_of?(Array) ? args.dup : [args]
          # Replacing $(value) is just one part, need to resolve any build settings present too.
          resolved_args = resolved_args.map { |a| a.gsub("$(value)", value) }.join(" ")
          Fastlane::Actions::ReadXcconfigAction.resolve_value(
            resolved_args,
            key: "resolved_args",
            resolved: {},
            parent: build_settings
          )
        end
      end

      ###
      # @!group Evaluating Conditions
      ###

      # Constants for condition evaluation.

      # Value to use for `NO`.
      NO = false
      # Value to use for `YES`.
      YES = true

      # Evaluate and check the condition.
      # Conditions come in form like this:
      # "$(COMPILER_INDEX_STORE_ENABLE) == YES  ||  ( $(COMPILER_INDEX_STORE_ENABLE) == Default  &&  $(GCC_OPTIMIZATION_LEVEL) == 0 )"
      # Return true if there's no condition to evaluate.
      # @param [Hash] option Xcspec option for build setting.
      # @param [Hash] build_settings All resolved build settings.
      # @return [Boolean] A Boolean indicating whether condition passes or not.
      def check_condition(option, build_settings)
        condition = option["Condition"]
        return true unless condition

        # Need to resolve all $(VAR) references using build settings.
        # At this point using complete build settings,
        # which include default values for all known build settings.

        # Handy that read_xcconfig action already has a helper to resolve a value.
        # Just pass current build settings as parent config.
        resolved_condition = Fastlane::Actions::ReadXcconfigAction.resolve_value(
          condition,
          key: "condition",
          resolved: {},
          parent: build_settings
        )

        # Resolved condition is now a C-like expression, which also can be evaluated as Ruby code.
        # With small changes though.
        # All literals in condition can be treated as strings, except for YES/NO boolean literals,
        # which are replaced with `true` and `false`.
        # However, xcspecs are very inconsistent when it comes to strings.
        # Some values are used unquoted in the conditions, such as:
        # Default, mh_object, bitcode.
        # There's also use of '' and \"\" for empty string, the latter may cause issues.
        # Then "same-as-input" that may have to be resolved - do not handle for now.
        # Finally, $(variant) == profile - just leave it for now.

        # Ways to fix.
        # 1. Scan for all enums in xcspecs and define module vars for each enum value,
        # so when evaluated, is replaced with variable.
        # 2. Process resolved condition by wrapping all unwrapped entries in quotes.
        # Using approach 2 for now with insane regex.

        # In all cases replace \"\" with ''.
        resolved_condition.gsub!('"', "'")

        # Quote everything except YES and NO.
        resolved_condition = (" " + resolved_condition + " ").gsub(/\s((\w|\d|-|\+|\.)+?)\s/, " '\\1' ").gsub(/'(YES|NO)'/, '\\1')

        begin
          # rubocop:disable Security/Eval
          eval(resolved_condition)
          # rubocop:enable Security/Eval
        rescue SyntaxError
          # Values like USE_LLVM_TARGET_TRIPLES_FOR_CLANG are not defined anywhere.
          # Those will be resolved into nothing and result into condition that can't be evaluated.
          false
        end
      end
    end
  end
end
