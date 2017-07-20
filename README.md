# logstash-commvault-output
Logstash output plugin for commvault datacube endpoint.
This output lets you send events to a DataCube endpoint.

### Documentation
Here is a link to the Data Cube [documentation.](http://documentation.commvault.com/commvault/v11/article?p=features/data_cube/c_data_cube_overview.htm)

Check out the [wiki](https://github.com/CommvaultEngg/logstash-commvault-output/wiki) for further details.

### Features
* Write to commvault open data source endpoint and visualize the data using commvault custom reports engine.
* Bulk inserts which is configurable.
* Template file for schema.

### Installation

Before using this plugin, make sure [logstash](https://www.elastic.co/downloads/logstash) is installed on your computer.



Download the release from this [link](https://github.com/CommvaultEngg/logstash-commvault-output/releases/download/0.1.0/logstash-output-cv-0.1.0.gem).



Execute

```sh
logstash-plugin install logstash-output-cv-0.1.0.gem
```

### Usage Example. 

Use the following logstash output configuration to write into commvault data.

    output
    {
        cv{
                    hostname_cv => "<Commvault web server endpoint address>"
                    http_method => "post"
                    username_cv => "<Commvault username>"
                    password_cv => "<Base64 encoded commvault password>"
                    datasourcename_cv => "<Descriptive data source name for commvault endpoint>"
                    idle_flush_time => <Flushinterval>
                    
                    headers => {
                            "Accept" => "application/json"
                            "Content-type" => "application/json"
                    }
                    flush_size => <Bulk flush size>
                    format => "json"
                    template_file=>"path\to\json\template"
                    analytics_engine_name => "<Commvault analytics engine client name>"
            }
    }
