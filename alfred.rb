require "hiera"
require "deep_merge"
require "optparse"
require "yaml"
require "pathname"
require "erb"
require "ostruct"

# Use this lookup as default for components
DEFAULT_COMPONENT_LOOKUP = {
  :behavior => 'hash',
  :strategy => 'deeper',
  :merge_hash_arrays => 'true'
}

AUTO_GEN_COMMENT     = "%s THIS IS AN AUTO-GENERATED FILE\n"
POUND_COMMENT        = %w[yaml properties py]
DOUBLE_SLASH_COMMENT = %w[json]
MANIFEST_NAME        = "init.rb"
LOOKUP_OPTIONS_KEY   = "lookup_options"
TARGET_DIR_KEY       = "%s::target_file_names"

# Loads a module's manifest in memory.
# @returns [Boolean]    true if the module is successfully loaded else returns false
def load_entity(entity, entity_type)
  case entity_type
  when :service
    entity_dir = File.join("hieradata", "modules")
  when :component
    entity_dir = File.join("hieradata", "components")
  else
    raise "Unknown entity type"
  end
  manifest_path = File.join(entity_dir, entity, "manifests", MANIFEST_NAME)
  if File.exists?(manifest_path)
    load manifest_path
    return true
  end
  puts "Missing manifest for #{entity}. Skipping properties generation"
  return false
end

# Get the respective manifest name for the given service.
# @param [String]    hierarchy_name    The hierarchy name which would contain manifest
# @return [String]                     Camel cased service name which reflects a manifest name for the service
def get_manifest_name(hierarchy_name)
  hierarchy_name.split(/[_.-]/).collect(&:capitalize).join
end

# Load the object of the entity from its manifest
# @param [String]  entity       Name of the entity
# @param [Symbol]  entity_type  Entity type, either :service or :component
def load_entity_object(entity, entity_type)
  case entity_type
  when :component
    load_entity(entity, :component)
  when :service
    load_entity(entity, :service)
  else
    return nil
  end
  return Object.const_get(get_manifest_name(entity)).new
end


# Lookup a given lookup_value through hiera. Here we also check compatibility of the installed hiera version. If a lower
# version of hiera is detected, `:deep_merge_options` are disabled.
#
# @param  [String]   lookup_value  Value to look for through Hiera
# @param  [Object]   default       Default value to return when lookup return nil
# @param  [Hash]     options       Additional lookup options to be provided to hiera.
# @param  [Hash]     scope         Hiera scope
# @return [Object]                 The lookup value obtained by hiera lookup
def lookup(lookup_value, default=nil, options, scope)
  if !options.nil? && !options.fetch(:behavior, nil).nil?
    installed_hiera_version = Gem::Version.new(Hiera.version.to_s)
    required_hiera_version = get_gem_version('hiera')
    if installed_hiera_version > required_hiera_version
      merge_options = options.clone
      merge_options.delete(:behavior)
      $hiera.config[:deep_merge_options] = merge_options
    elsif installed_hiera_version < required_hiera_version
      puts "Lower version of hiera detected than requirement. This can lead to unexpected results."
    end
    default_strategy = $hiera.config[:merge_behavior]
    $hiera.config[:merge_behavior] = options[:strategy]
    config_value = $hiera.lookup(lookup_value, default, scope, nil, options[:behavior].to_sym)
    $hiera.config[:merge_behavior] = default_strategy
  else
    config_value = $hiera.lookup(lookup_value, default, scope, nil)
  end
  config_value
end


# Lookup configs through hiera for the given entity_vars
# @param  [String]         entity       Name of the entity
# @param  [Symbol]         entity_type  Entity type, either :service or :component
# @param  [Array<String>]  entity_vars  Array of all the instance variables from the service manifest
# @param  [Hash]           scope        The scope generated at input to be used for hiera lookups
def lookup_entity_vars!(entity, entity_type, entity_vars, scope, configs)
  scope = scope.merge({entity_type.to_s => entity})
  lookup_options = $hiera.lookup(LOOKUP_OPTIONS_KEY, {}, scope)
  new_configs = {}
  entity_vars.each do |var|
    config_key = "#{var}".sub("@", "")
    next if config_key == "components" || config_key == "modules"
    lookup_value = "#{entity}::#{config_key}"
    config_value = lookup(lookup_value, nil, lookup_options&.[](lookup_value), scope)
    new_configs[config_key] = config_value
  end
  configs.deep_merge!(new_configs)
end


# Build configurations for the provided entities
# @param  [Array<String>]    entities     A list of entities to build configurations
# @param  [Symbol]           entity_type  Entity type, either :service or :component
# @param  [Hash]             scope        The scope generated at input to be used for hiera lookups
# @return [Hash]                          A hash of all parsed configs
def build_configs(entities, entity_type, scope)
  configs = {}
  entities.each do |entity|
    entity_obj = load_entity_object(entity, entity_type)
    if entity_type == :service
      # load any dependent modules first for a service
      modules = entity_obj.instance_variable_get(:@modules)
      if !!modules
        parsed_mods = []
        modules.each do |mod|
          raise "Circular module dependency detected in module #{mod}" if !parsed_mods.empty? && parsed_mods.include?(mod)
          parsed_mods << mod
          raise "Could not find module #{mod}" unless load_entity(mod, :service)
          mod_obj = load_entity_object(mod, :service)
          lookup_entity_vars!(mod, :service, mod_obj.instance_variables, scope, configs)
        end
      end
    end
    # load the current entity
    lookup_entity_vars!(entity, entity_type, entity_obj.instance_variables, scope, configs)
    if entity_type == :service
      # load all dependent components
      components = entity_obj.instance_variable_get(:@components)
      if !!components
        components.each do |component|
          component_obj = load_entity_object(component, :component)
          lookup_entity_vars!(component, :component, component_obj.instance_variables, scope, configs)
        end
      end
    end
  end
  return configs
end


def _get_hiera_config(args)
  hiera_yaml = Pathname.new("hiera.yaml").realpath.to_s
  config = YAML.load_file(hiera_yaml)
  unless args[:debug]
    config[:logger] = 'noop'
  end
  config
end

# Validate that service name is provided and only one of env or node is provided
# @param [Object]  args   Input arguments passed to script
def validate_input(args)
  if args[:comp].nil?
    raise OptionParser::MissingArgument.new('Please provide either of --service or --component to build properties') \
    if args[:service].nil?
    raise OptionParser::MissingArgument.new('Missing argument --role with --node') if !!args[:node] && args[:role].nil?
    raise OptionParser::MissingArgument.new('Missing argument --node with --role') if args[:node].nil? && !!args[:role]
  end
end

# Generate a configuration file for an entity from provided configs. The config file is written to the target_dir
# @param  [Array<String>]   entities     A list of entity names to generate configuration files from the provided config
# @param  [Symbol]          entity_type  Entity type, either :service or :component
# @param  [Hash]            configs      A hash of generated configs
# @param  [Boolean]         dry_run      If true, the configs are only printed to the console
# @param  [String]          target_dir   The directory to write the configuration file. Default ../{service}/configs/
# @param  [Hash]            scope        The scope generated at input to be used for hiera lookups
# @param  [Boolean]         clean        Clean the target directory before writing files.
def generate_config_file(entities, entity_type, configs, dry_run, target_dir, scope, clean = false)
  entities.each do |entity|
    # Get lookup options
    scope = scope.merge({entity_type.to_s => entity})
    lookup_options = $hiera.lookup(LOOKUP_OPTIONS_KEY, {}, scope)

    # Get target_dir from configs
    target_dir_key = TARGET_DIR_KEY % entity
    target_dir_config = lookup(target_dir_key, [{ :target_dir => target_dir }], lookup_options&.[](target_dir_key), scope)

    validate_target_files(target_dir_config)
    target_dir_config.each do |config|
      if !config['target_dir'] 
        # Get default target directory
        config['target_dir'] = File.join(Dir.pwd, "#{entity_type}s", "#{entity}", "configs")
      end
    end
    
    entity_configs_data = []
    entity_template_dir = File.join('hieradata', 'modules', entity, 'templates')
    target_dir_config.each do |target_dir|
      files = target_dir&.[]("files")
      files.each do |file|
        entity_configs_data << {
          :target_dir => target_dir&.[]('target_dir'),
          :name       => file&.[]('name') || target_and_template[:template].chomp(".erb"),
          :data       => render_template(File.read(File.join(entity_template_dir, file&.[]('template'))), configs),
        }
      end
    end

    if dry_run
      entity_configs_data.each do |entity_configs_data_item|
        file_name = File.join(entity_configs_data_item[:target_dir], entity_configs_data_item[:name])
        puts file_name
        puts entity_configs_data_item[:data]
      end
    else
      if clean && Dir.exists?(entity_configs_data_item[:target_dir])
        puts "Cleaning #{entity_configs_data_item[:target_dir]}"
        FileUtils.rm_rf(Dir[File.join(entity_configs_data_item[:target_dir], "*")])
      end
      entity_configs_data.each do |entity_configs_data_item|
        FileUtils.mkdir_p(entity_configs_data_item[:target_dir]) unless Dir.exists?(entity_configs_data_item[:target_dir])      
        File.open(File.join(entity_configs_data_item[:target_dir], entity_configs_data_item[:name]), 'w') do |f|
          f.write(entity_configs_data_item[:data])
        end
      end
    end
  end
end


# Validate the target dirs
# @param [Object]  target_config     Validate the provided target_dir_config
def validate_target_files(target_config)
  # target_config should be an array
  require_relative "validation_error"
  raise ValidationError.new("target_dir_config should be an Array") unless target_config.is_a?(Array)

  target_config.each do |config|
    # Each element must have `target_dir` and `files`
    raise ValidationError.new("Each element must have `target_dir` and `files`") unless config.key?("target_dir") && config.key?("files")
    files = config["files"]
    # Files in target_file_names should be a list
    raise ValidationError.new("Files in target_file_names should be a list") unless config["files"].is_a?(Array)
    config["files"].each do |file_config|
      raise ValidationError.new("Each file configuration must contain keys `template` and `name`") unless file_config.key?("template") && file_config.key?("name")
      
    end
  end
end

def render_template(template, configs)
  # Instantiate ERB in trim mode
  return ERB.new(template, nil, '-').result(OpenStruct.new(configs).instance_eval { binding })
end

args = {}

ARGV << '-h' if ARGV.empty?

OptionParser.new do |opts|
  opts.on("--service s1,s2,s3", "Service name", Array, "List of services to build") do |serv|
    args[:service] = serv
  end

  opts.on("--components c1,c2,c3", "-c c1,c2,c3", Array, "List of components to built") do |comp|
    args[:comp] = comp
  end

  opts.on("--env env", "Generate properties specific to the given environments") do |env|
    args[:env] = env
  end

  opts.on("--node node", "Generate service properties for node") do |node|
    args[:node] = node
  end

  opts.on("--role role", "Role of the given node") do |role|
    args[:role] = role
  end

  opts.on("--target-dir file", "Target file path to place the generated properties. Default: ../{service}/configs/") do |target_dir|
    args[:target_dir] = target_dir
  end

  opts.on("--dry-run", "Only generate properties without substituting to template") do |dry_run|
    args[:dry_run] = dry_run
  end

  opts.on("--validate", "-v", "Validate configurations after generation") do
    args[:validate_properties] = true
  end

  opts.on("--clean", "Clean the target directory before writing configuration files") do
    args[:clean] = true
  end

  opts.on("--debug", "-d", "Execute in debug mode") do |debug|
    args[:debug] = debug
  end

  opts.on("-h", "--help", "Help") do
    puts opts
    exit
  end

end.parse!

$hiera = Hiera.new(:config => _get_hiera_config(args))
validate_input(args)
scope = Hash.new
scope['env']     = args[:env] if args.key?(:env)
scope['node']    = args[:node] if args.key?(:node)
scope['role']    = args[:role] if args.key?(:role)

if !!args[:service]
  # service_configs = generate_service_properties(args[:service], scope)
  # generate_properties_file(args[:service], service_configs, args[:dry_run], args[:target_dir], false) unless service_configs.nil?
  configs = build_configs(args[:service], :service, scope)
  generate_config_file(args[:service], :service, configs, args[:dry_run], args[:target_dir], scope, args[:clean])
else
  # TODO: Fix component configs
  components = build_configs(args[:comp], :component, scope)
  generate_properties_file(args[:comp], components, args[:dry_run], args[:target_dir], true, args[:validate_properties]) unless components.nil?
end


# 1. Get and validate inputs
# 2. Load Hiera
# 3. for each service/component
#   1. Load service manifest
#   2. Lookup service configs with Hiera
#   3. Lookup service components
#   4. Recursively lookup modules
#   5. Merge 2,3,4
# 4. Generate configurations
#     1. If target_dir is provided, then lookup directory and templates
#     2. If target_dir is not provided, then use default directory and get all templates under `templates` directory
#     3. Load configs into erb templates
#     4. Add autogen comment on the top of generated configs
#     5. If not dry run, write the configs to a file
