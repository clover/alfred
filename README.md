# Creating properties for service

## Prerequisites
1. Ruby >= 1.8
2. Bundler >= 2.1.4

## Installation
Use bundler to install required dependencies.
```
bundler install
```

## Directory Structure
```
alfred
    |
    | - hieradata
    | | - components
    | | - common
    | | - modules
    | | | - data
    | | | - manifests
    | | | - templates
    | | - nodes
    | | - roles
    | | - env
    | - hiera.yaml
    | - Gemfile
    | - Gemfile.lock
    | - generate_properties.rb
```

Properties for a service can be specific to an environment or a node or can be a part of a component or node.
All of these properties are located in `properties/hieradata/` directory.
 - **Components**: Component based configurations can be defined as a configuration used to achieve a common purpose. These are defined as separately buildable components under the `hieradata/components` directory.
 - **Module**: Properties mentioned here will be present in the service as mentioned, which is, **they will not be overridden** by any environment or node properties. Module specific properties should be mentioned under the `properties/hieradata/<module_name>/data/<module_name>.yaml` file.
 - **Environment**: Environment properties contain properties that change in different environments (localhost, dev, production, etc.) for a service. For example, we use a different main port and admin port in localhost and test environments. These properties should be mentioned under the `properties/hieradata/env/<environment_name>/<service_name>.yaml` file.
 - **Node**: Node properties are for services that run in a distributed environment, that is where multiple services are running across different nodes. These nodes can be defined using properties from **roles**, which can be like master, slave, backup, etc., which can be found in the `properties/hieradata/roles/<role_name>.yaml` files. Node specific properties can be defined in the `properties/hieradata/node/<node_name>.yaml` file.
 - **Common**: Defaults for a service. These properties can be overridden in modules, environments, appenvs, nodes, and roles. Common properties should be mentioned in the `properties/hieradata/common/<service_name.yaml>` file.

There are two individually buildable elements: Components and Modules. These elements are defined using the following parts:
- **Data**: Each element should contain a data directory which would in turn contain a yaml file to actually define what properties go into each element. Every property in the yaml file should be defined using a prefix. The format for a service property can be `<service_name>::<property_key>` or `component::<component_name>`. The later one is used to define components.
- **Templates**: Templates are used to define the structure of the property file. These are `erb` templates and are substituted with values from yaml files in the data directory of the respective element.
- **Manifests**: Manifest contains a list of all the properties that can be present across all the templates. This manifest has the following properties:
  - The file name of the manifest should be `init.rb`. It is a ruby class.
  - This class should have the same name as of the respective element in camel casing.
  - This class can have all the properties under the `attr_accessor` field. Each property under this field should be prefixed with a colon(:). This is a ruby "symbol".
  - This class should also contain a method called `initialize()` which is a constructor for this class and is used to initialize all the properties.
  - All properties are initialized as `@<property_name> = nil`, which is the property name, prefixed with `@` and set to nil.
  - When defining service properties, this class can additionally include `:components` which will be intialized to an array of Strings containing the names of components which will be used in the service.

**Note:** This directory structure can be changed by changing the hierarchy in `hiera.yaml`

## Adding service properties

Let's take an example and define echo-server's properties

1. Under `properties/hieradata/modules` create a new directory with the service name.
2. Under this directory add three more directories, `data`, `templates` and `manifests`.
3. In the `data` directory, create a file, `echo-server.yaml`. This file should contain all the properties that will be in echo-server in every deployment as is. That is, **these properties will not change in any deployments**.
```
echo-server::service_name: echo-server
```
4. To add other properties that can differ in different environments, add them to `properties/hieradata/common/echo-server.yaml` file.
```
echo-server::host_tag: localhost
```
5. Let's add properties that will change with different deployments. For example `port` and `adminPort` for echo-server are different in `test` and `localhost` deployment of the service.
To add those properties create a new directory with the service name as `env/test/echo-server.yaml` and `env/localhost/echo-server.yaml` and add the properties in these files.
The `env/test/echo-server.yaml` will be as follows:
```
echo-server::port: 8080
echo-server::target_file_names:
    target_dir: ~
    files:
      - template: echo.properties.erb
        target_file_name: test.echo.properties
```
Here we use the `target_file_names` to define the name of files generated from each template. Since here the file name changes in a test deployment, we've added this property in `env/test/echo-server.yaml`.
The `target_file_names` key should define 2 values:
- `target_dir` to define the directory path to be used the generated property file. If `~` is given, then the service's resources directory is used.
    *Note:*
     - A directory path is created if it does not exist.
     - If a target directory is provided with `--target-dir`, it takes higher precedence than `target_file_names.target_dir`
- `files` contains a list of names target files and templates to be used for generating those files.
      - `template` defines the template name
      - `target_file_name` defines the file name for the properties.
6. In the `templates` directory, create a new file for each property file required by the service. In our case there is only one property file, so create the `echo-server.properties.erb` file.
7. Add the following to the template file.
```
<% unless service_name.nil? -%>
serviceName=<%= service_name %>
<% end -%>
<% unless port.nil? -%>
port=<%= port %>
<% end -%>
<% unless host_tag.nil? -%>
hostTag=<%= host_tag %>
<% end -%>
<% unless components.nil? -%>
<% components.values.each do |property| %>
<%= property -%>
<% end -%>
<% end -%>
```
Here we only include properties that are not set to nil. In other words, properties will only be added to this file if they are not nil.
As this is an embedded ruby (erb) template we can perform different operations such as manipulating a property, joining a list based property with a delimiter, etc.
At the end of the file we add components by iterating through the components array.

8. In the `manifests` directory, create a file `init.rb`. This file should contain a ruby class defined as follows:
```
class echoServer
  attr_accessor :service_name,
                :port,
                :host_tag,
                :components
  def initialize()
    @service_name = nil
    @port = nil
    @host_tag = nil
    @components = ['memcached']
  end
end
```
This class contains all the properties that are used by the echo-server service with a list of components. These variables are available with the defined property to be substituted in the erb templates defined in the templates folder.

9. The properties file can now be generated. The generation is done by running the `properties/generate_properties.rb` script.
The script can take the following arguments:
- `--service SERVICE` the name of the service.
- `--component [C1,C2,...]` generate properties for a list of provided components.
- `--env ENVIRONEMNT` deployment environment for the service.
- `--node NODE` deployment node for the service.
- `--role ROLE` deployment role for the node where the service will be deployed.
- `--target DIR_PATH` path to place generated properties.  Defaults: For a service, the default target dir will be the `server/<service_name>/src/main/resources/`. For components the default will be the current working directory.
- `--dry-run` if this argument is set then the generated properties will only be printed on the console.
- `--debug` if this argument is set then the script will also print lookup logs to console.
- `--help` prints help for the service.
The rules for these arguments are described as follows:
- Only one of `--service` or `--component` should be provided.
- Only one of `--env` or `--node` should be used.
- When defining properties using `--node` a `--role` should be provided. Also `--role` should only be used when defining `--node` properties.
Properties can be generated for echo-server through `properties$ ruby generate_properties.rb --service echo-server --env localhost`
  

## Adding a property for an already existing service
To add property to an already existing service first add the property in `properties/hieradata/modules/<service_name>` in two places:
 - Add and initialize the property in `manifests/init.rb` as explained in manifest description.
 - Add the property in `templates/<property_template_name>.erb` in the desired location.

Add the property value according to the following conditions:
 - If this property will remain same in all the service deployments, then in the directory `properties/hieradata/modules/<service_name>/` add the property prefixed with `<service_name>::` to `data/<service_name>.yaml`.
 - If this property should only exists based on where the service is being deployed to, add the property prefixed with `<service_name>::` in `properties/hieradata/<target_envrionment>/<service_name>.yaml`. If this property changes when adding appenvs/nodes/roles, then also make sure to add the property in the respective definitions.
 - If this property can change but on different deployments but should be set to default when it is not defined in the deployment environment, then add the property to `properties/hieradata/common/<service_name>.yaml`.

## Creating components

Components are reusable configurations that can be used across different modules. Components are defined in the directory `properties/hieradata/components` in a similar way to modules.
To create a component, for example memcached,

1. Create a directory in `properties/hieradata/components/` with name of the name of the component.
2. Create three directories under components: `data`, `templates`, `manifests`.
3. In the data directory, create a yaml file with the name of the component: `memcached.yaml`.
4. In the `manifests` directory, create a file `init.rb`.
5. In the `templates` directory, create a file `<component-name>.<file_extension>.erb` (`memcached.properties.erb`)
6. In the yaml file under the data directory we add component properties prefixed with `component::`. In our case, we define properties in `memcached.yaml` as follows:
```
component::memcached:
component::memcached:
  nodes: localhost:11211
  single_client_enabled: true
```
7. The values defined under `component::memcached` are considered as defaults for the components and can be overridden at any higher level of hierarchy.
The overridden values are merged with the default using merges. The default merge options for components are as follows:
```
{
    :behavior => 'hash',  # Indicates what kind of hiera lookup is used. Refer more about lookup_types here -> https://puppet.com/docs/hiera/1.3/lookup_types.html
    :strategy => 'deeper', # Indicates what a strategy for lookup if lookup_type is hash. Values can be either one of 'priority', 'deep' or 'deeper'. [Note: It is not recommended to use the 'deep' strategy]
    :merge_hash_arrays => 'true' # Any other merge options follow here. Some examples for deeper merge options can be referred here -> https://github.com/danielsdeleo/deep_merge#options
}
```
Custom merge options for a service can be provided by adding a `lookup_options.yaml` in the data directory of either a module or a component.
8. To provide environment based overrides for the defined component values, create a yaml file with under the `env/<env_name>` directory and provide the override values.
For example, to define override values for memcached in the test environment, create a file `memcached.yaml` under the `env/test` directory and provide the following overrides:
```
component::memcached:
  nodes: localhost:11211
  single_client_enabled: false
```
9. Add the following definition in the `init.rb` file defined under the `manifests` directory
```
class Memcached
  attr_accessor :memcached

  def initialize()
    @memcached = nil
  end
end

```
This manifest file defines and initializes all the variables prefixed with `component::` in the yaml file for component.
10. Add the following template in the template file defined in the `templates` directory.
```
<% unless memcached.nil? -%>
<% if memcached.key?('pool_size') && !memcached['pool_size'].nil? -%>
memcachedPoolSize=<%= memcached['pool_size'] %>
<% end -%>
<% if memcached.key?('nodes') && !memcached['nodes'].nil? -%>
memcachedNodes=<%= memcached['nodes'] %>
<% end -%>
<% if memcached.key?('timeout_ms') && !memcached['timeout_ms'].nil? -%>
memcachedRequestTimeout=<%= memcached['timeout_ms'] %>
<% end -%>
<% if memcached.key?('single_client_enabled') && !memcached['single_client_enabled'].nil? -%>
memcachedSingleClientEnabled=<%= memcached['single_client_enabled'] %>
<% end -%>
<% end -%>

```
**Note:** Take special care when defining templates for files that rely on indentation. When this template is being merged with another template, the indentation of the final template might affect the defined indentation for the currently defined template.

## Reusing modules

Sometimes there is a need to include properties of one module in another to reduce the duplication of configurations between similar modules. This can be achieved by including a module in another module.
For example, let's assume we need to include module1 in module2. This can be achieved as follows:
1. In module2's `manifest/init.rb` file include the module as follows:
```
class Module1
    attr_accessor :prop1,
                  :prop2,
                  :module1_prop_to_override,
                  .
                  .
                  .
                  :module

    def initialize()
        @prop1 = nil
        @prop2 = nil
        @module1_prop_to_override = nil
        .
        .
        .
        @module2 = ['module1']
    end
end
```
In this manifest we include module1 within module2. We also want module2 to override some of module1's properties. To do this we initialize them back in module2.

2. In module2's template, add the properties which are to be included from module1. For example:
```
<% unless prop1.nil? -%>
prop1=<%= prop1 %>
<% end -%>
<% unless prop1.nil? -%>
prop2=<%= prop2 %>
<% end -%>
<% unless module1_prop_to_override.nil? -%>
module1_prop_to_override=<%= module1_prop_to_override %>
<% end -%>
<% unless module1_prop.nil? -%>
module1_prop=<%= module1_prop %>
<% end -%>
```

### Points to be noted
1. Any overridden properties should be present in the child module's properties. In this case module2 should define the following in one of the yaml files.
```
module2:::module1_prop_to_override: "foo"
```
2. Any components included in the parent will be added to the child module as is. To override them they should be included in the parent module or it might result in unexpected properties.
3. In the case of multi-level encapsulation, where module1 -> module2 -> module3, if there are any common components between any modules, then it can be uncertain which component configuration is picked up. To overcome this the component should be overridden for the child module.

## Validation
When moving static properties files to the properties module, there is a need to validate the generated properties file with the original properties file. This can be done as follows:
1. `bundler install --with test`. This installs the required `java-properties` package required for validation.
2. `properties$ ruby generate_properties.rb --service <service_name> --env <env> [--target-dir] [--dry-run] -v`
