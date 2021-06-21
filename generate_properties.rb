#!/usr/bin/ruby

require 'rubygems' # Need this to work with ruby version <= 2
require 'hiera'
require 'erb'
require 'optparse'
require 'ostruct'
require 'yaml'
require 'fileutils'
require 'pathname'
require 'deep_merge'


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


# Get the respective manifest name for the given service.
# @param [String]    hierarchy_name    The hierarchy name which would contain manifest
# @return [String]                     Camel cased service name which reflects a manifest name for the service
def get_manifest_name(hierarchy_name)
  hierarchy_name.split(/[_.-]/).collect(&:capitalize).join
end

# Gem version defined in the Gemfile
# @param [String]  gem_name   Name of the gem to lookup in GemFile
# @return Gem::Version      The version number defined in gem file in String format
def get_gem_version(gem_name)
  File.readlines('Gemfile').each do |line|
    if line.include?(gem_name)
      line.gsub!("'", "")
      version = line[line.index('=') + 1...line.length].strip!
      return Gem::Version.new(version)
    end
  end
end

# @param [String]  lookup_value     value to lookup in hiera backends.
# @param [Hash]    options   lookup options for value.
# @return [Hash]                    value fetched from the hiera backends.
def lookup(lookup_value, options, scope)
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
    config_value = $hiera.lookup(lookup_value, nil, scope, nil, options[:behavior].to_sym)
    $hiera.config[:merge_behavior] = default_strategy
  else
    config_value = $hiera.lookup(lookup_value, nil, scope, nil)
  end
  config_value
end

# @param [Array<String>]  components      Array of components to be parsed
# @param [Hash]           lookup_options  Parsed of module's lookup_options.yaml
# @return [Array]                          Key value pairs of component name and its substituted erb template in string format
def parse_components(components, scope, parsed_components = {}, lookup_options = {})
  configs = {}
  comp_templates = []
  use_comp_lookup = lookup_options.nil? || lookup_options.empty?
  components.each do |comp|
    next unless parsed_components.detect { |component| component[:name] == comp }.nil?
    scope['component'] = comp
    component_dir = File.join("hieradata", "components", comp)
    if File.exists?(File.join(component_dir, "manifests", MANIFEST_NAME))
      load File.join(component_dir, "manifests", MANIFEST_NAME)
    else
      puts "Missing manifest for #{comp}. Skipping properties generation"
      return nil
    end
    comp_obj = Object.const_get(get_manifest_name(comp)).new
    raise 'Could not find any declared variables in #{comp}\'s manifest. Please make sure variables are defined under \
           attr_accessor and initialized in the initialize method' if comp_obj.instance_variables.empty?
    comp_obj.instance_variables.each do |var|
      var = "#{var}".sub("@", "")
      lookup_value = "component::#{var}"
      lookup_options = $hiera.lookup('lookup_options', {}, { 'component' => comp }).
        fetch(lookup_value, nil) if use_comp_lookup
      config_value = lookup(lookup_value, lookup_options.nil? ? DEFAULT_COMPONENT_LOOKUP : lookup_options, scope)
      if config_value.nil?
        puts "Could not find values for component #{comp}"
        next
      end
      configs[var] = config_value
    end

    dir = File.join(component_dir, 'templates')
    Dir.foreach(dir) do |template|
      next if template == "." or template == ".."
      raise "Only erb templates are allowed" unless template.end_with?('erb')
      comp_templates << {
        :name => template.chomp('.erb'),
        :path => nil,
        :properties => erb(File.read(File.join(dir, template)), configs)
      }
    end
  end
  comp_templates
end

def load_module?(module_name)
  # Loads a module's manifest in memory.
  # @returns [Boolean]    true if the module is successfully loaded else returns false

  modules_dir = File.join("hieradata", "modules")

  if File.exists?(File.join(modules_dir, module_name, "manifests", MANIFEST_NAME))
    load File.join(modules_dir, module_name, "manifests", MANIFEST_NAME)
    return true
  end

  puts "Missing manifest for #{module_name}. Skipping properties generation"
  return false
end

# Lookup properties for a given module.
#
# @param [String] mod                Name of the module
# @param [Hash]   scope              The scope generated at input to be used for hiera lookups
# @param [Hash]   service_configs    A hash of any service configs that are already parsed from any dependent modules
# @returns [Hash]                    Updated service_configs hash
def lookup_properties(mod, scope, service_configs = {})
  mod_obj = Object.const_get(get_manifest_name(mod)).new
  instance_properties = mod_obj.instance_variables
  lookup_options = $hiera.lookup('lookup_options', {}, { 'service' => mod })
  instance_properties.each do |var|
    config_key = "#{var}".sub("@", "")
    next if config_key == "components"
    lookup_value = "#{mod}::#{config_key}"
    scope['service'] = mod
    config_value = lookup(lookup_value, lookup_options.fetch(lookup_value, nil), scope)
    service_configs[config_key] = config_value
  end

  if instance_properties.to_s.include?("@components")
    service_configs['components'].concat(parse_components(mod_obj.instance_variable_get(:@components), scope,
                                                          service_configs['components'], lookup_options))
  end
  service_configs
end

# Recursively parse dependent modules modules provided in the 'modules' instance variable of the manifest.
# This will also raise an exception if a circular dependency of modules is detected (A -> B -> A).
#
# @param [Array<String>]  modules                   An array containing a list of dependent modules
# @param [Hash]           service_configs           A hash containing any service configs already parsed
# @param [Hash]           scope                     The scope generated at input to be used for hiera lookups
# @param [Array<String>]  parsed_modules            An array containing a list of already parsed modules
# @return [Hash]                                    A hash of updated service_configs
def parse_modules(modules, service_configs, scope, parsed_modules = [])
  modules.each do |mod|
    raise "Circular module dependency detected in module #{mod}" if !parsed_modules.nil? && parsed_modules.include?(mod)
    parsed_modules << mod
    raise "Could not find module #{mod}" unless load_module?(mod)
    mod_obj = Object.const_get(get_manifest_name(mod)).new
    instance_properties = mod_obj.instance_variables
    if instance_properties.to_s.include?("@modules")
      service_configs.deep_merge!(parse_modules(mod_obj.instance_variable_get(:@modules), service_configs, scope, parsed_modules),
                                  { :extend_existing_arrays => true })
    end
    return lookup_properties(mod, scope, service_configs)
  end
  return service_configs
end

# Generate service properties by substituting erb templates in the templates directory for the module.
# All properties are listed in init.rb for each module, and properties are looked up in the format <module_name>::<config_value>.
# Components are separately parsed from the @components in init.rb. Each component is looked up using component::<component_name>.
# Each component has its own template which are first substituted and then merged with the module's generated template.
#
# @param  [String]        service_name  Name of the module
# @param  [scope]         scope         The scope generated at input to be used for hiera lookups
# @return [Array<Hash>]                 An array of hashes containing file_name, file_path, properties and boolean to clean the target
#                                       directories of the file to be generated
def generate_service_properties(service_name, scope)
  modules_dir = File.join("hieradata", "modules")
  return nil unless load_module?(service_name)

  service_configs = { 'components' => [] }
  service_obj = Object.const_get(get_manifest_name(service_name)).new
  if service_obj.instance_variables.to_s.include?("@modules")
    service_configs = parse_modules(service_obj.instance_variable_get(:@modules), service_configs, scope)
  end

  service_configs = lookup_properties(service_name, scope, service_configs)

  configs = []
  # Target file names should be provided in a hash under <service_name>::target_file_names. The values should contain the
  # keys "template_name" to specify the template name and "target_file_name" to specify the target file name.
  target_file_names = $hiera.lookup(service_name + "::target_file_names", [], scope)
  service_template_dir = File.join(modules_dir, service_name, "templates")
  service_templates = []
  Dir.foreach(service_template_dir) do |template|
    next if template == "." or template == ".."
    service_templates << template
  end
  if target_file_names.nil? || target_file_names.empty?
    service_templates.each do |template|
      template_file = File.join(service_template_dir, template)
      properties = erb(File.read(template_file), service_configs)
      configs << {
        :name => template.chomp(".erb"),
        :properties => properties
      }
    end
  else
    validate_target(target_file_names, service_templates)
    target_file_names.each do |target|
      target['files'].each do |file|
        template_file = File.join(service_template_dir, file['template'])
        configs << {
          :name => file['name'],
          :path => target['target_dir'],
          :clean => target.fetch('clean', 'false'),
          :properties => erb(File.read(template_file), service_configs)
        }
      end
    end
  end
  configs
end

def validate_target(target_file_names, service_templates)
  target_file_names.each do |target|
    raise 'No files detected under target_file_names' unless target.key?('files')
    raise 'No target directory found under target_file_names.' unless target.key?('target_dir')
    target['files'].each do |file|
      raise 'Missing file name' unless file.key?('name')
      raise "Missing template for file #{file}" unless file.key?('template')
      raise 'Only erb templates are allowed' unless file['template'].end_with?('erb')
      raise 'Only erb templates are allowed under the service templates directory' unless service_templates.any? { |template| template.end_with?('erb') }
      raise "Template #{file['template']} not found in service templates" unless service_templates.include?(file['template'])
    end
  end
end

def validate_properties(property, path)
  begin
    require 'java-properties'
  rescue LoadError
    puts 'Cannot find java-properties gem installed.'
    puts 'Use bundler install --with test to install gems required to validate'
  else
    file_path = File.join(path, property[:name])
    if !File.exists?(file_path)
      puts "Cannot find existing properties at #{file_path}. Skipping validation."
    else
      actual = JavaProperties.load(file_path)
      expected = JavaProperties.parse(property[:properties])
      puts "Checking equality"
      if expected != actual
        if expected.size > actual.size
          diff = expected.to_a - actual.to_a
        else
          diff = actual.to_a - expected.to_a
        end
        puts File.join(path, property[:name])
        require 'pp'
        pp Hash[*diff.flatten]
        abort("Exiting!")
      end
    end
  end
end

# Add the AUTO_GEN_COMMENT at the beginning of properties based on file extension
#
# @param [String]     properties    Generated properties in string format
# @param [String]     extension     Extension of the properties file to be generated
# return [String]                   Properties with added AUTO_GEN_COMMENT comment
def add_autogen_comment_properties(properties, extension)
  if POUND_COMMENT.include?(extension)
    properties = AUTO_GEN_COMMENT % ["##", "##"] + properties
  elsif DOUBLE_SLASH_COMMENT.include?(extension.to_sym)
    properties = AUTO_GEN_COMMENT % ["//", "//"] + properties
  end
  return properties
end

# Clean the "target_dir" when clean is set to true
# @param  [Hash]    configs       config hash containing :name, :path, :clean and :properties
def clean_target_dir(configs)
  configs.each { |config| FileUtils.rm_rf(config[:path]) if config[:clean] == "true" }
end

# Generate properties file from the service template. Generated properties files will be placed in service's resources
# directory.
#
# @param [String]   name          name for the element to be built
# @param [Boolean]  dry_run       Set to false if properties file should be generated else only properties will be
#                                 printed on the console
# @param [Hash]     configs       Hash containing pairs of target file names and substituted erb templates
# @param [Object]   target_dir    Optional param to provide the designated directory to place the generated properties
# @param [Boolean]  is_component  create file for component properties
def generate_properties_file(name, configs, dry_run, target_dir, is_component, validate = false)
  service_resources = File.join("..", name, "src", "main", "resources")
  clean_target_dir(configs) unless dry_run
  configs.each do |file|
    if !target_dir.nil? && !target_dir.empty?
      path = target_dir
    elsif is_component
      # Use the current working directory if generating properties for a component and no target-dir is provided
      path = Dir.pwd
    else
      # Use the target path provided in yaml files. If no target path is found then try using service's resources folder,
      path = file.fetch(:path, nil)
      path ||= service_resources
    end
    ext = file[:name].split(".")[-1]
    validate_properties(file, path) if validate
    property_content = add_autogen_comment_properties(file[:properties], ext)
    if dry_run
      puts File.join(File.expand_path(path), file[:name])
      puts property_content
    else
      # Create target directory if not exists
      FileUtils.mkdir_p(path) unless File.directory?(path)
      File.open(File.join(path, file[:name]), "w") do |f|
        f.write(property_content)
      end
      puts "Successfully generated #{File.join(File.expand_path(path), file[:name])}"
    end
  end
end

# Update template based on the @substitution Hash generated in the generate_service_properties method
# @param [String]  template Parsed properties template file as a string
# @param [Hash]  values substitution values to be applied on
# @return [String] updated erb template
def erb(template, values)
  # Instantiate ERB in trim mode
  ERB.new(template, nil, '-').result(OpenStruct.new(values).instance_eval { binding })
end

args = {}

ARGV << '-h' if ARGV.empty?

OptionParser.new do |opts|
  opts.on("--service SERVICE", "Service name") do |serv|
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

  opts.on("--target-dir file", "Target file path to place the generated properties. Default: ../{service}/src/main/resources/") do |target_dir|
    args[:target_dir] = target_dir
  end

  opts.on("--dry-run", "Only generate properties without substituting to template") do |dry_run|
    args[:dry_run] = dry_run
  end

  opts.on("--validate", "-v", "Validate configurations after generation") do
    args[:validate_properties] = true
  end

  opts.on("--debug", "-d", "Execute in debug mode") do |debug|
    args[:debug] = debug
  end

  opts.on("-h", "--help", "Help") do
    puts opts
    exit
  end

end.parse!

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

validate_input(args)
scope = Hash.new
scope['service'] = args[:service]
scope['env'] = args[:env] if args.key?(:env)
scope['namespace'] = args[:namespace] if args.key?(:namespace)
scope['node'] = args[:node] if args.key?(:node)
scope['role'] = args[:role] if args.key?(:role)

$hiera = Hiera.new(:config => _get_hiera_config(args))
if !!args[:service]
  service_configs = generate_service_properties(args[:service], scope)
  generate_properties_file(args[:service], service_configs, args[:dry_run], args[:target_dir], false) unless service_configs.nil?
else
  components = parse_components(args[:comp], scope)
  generate_properties_file(args[:comp], components, args[:dry_run], args[:target_dir], true, args[:validate_properties]) unless components.nil?
end
