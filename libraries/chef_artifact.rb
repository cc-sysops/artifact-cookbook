class Chef
  module Artifact
    DATA_BAG = "artifact".freeze
    NEXUS_DBI = "nexus".freeze

    module File

      # Returns true if the given file is a symlink.
      # 
      # @param  path [String] the path to the file to test
      # 
      # @return [Boolean]
      def symlink?(path)
        if windows?
          require 'chef/win32/file'
          return Chef::ReservedNames::Win32::File.symlink?(path)
        end
        ::File.symlink?(path)        
      end

      # Returns the value of the readlink method.
      # 
      # @param  path [String] the path to a symlink
      # 
      # @return [String] the path that the symlink points to
      def readlink(path)
        if windows?
          require 'chef/win32/file'
          return Chef::ReservedNames::Win32::File.readlink(path)
        end
        ::File.readlink(path)
      end

      # Generates a command to execute that either uses the Unix cp
      # command or the Windows copy command. 
      #
      # @param  source [String] the file to copy
      # @param  destination [String] the path to copy the source to
      # 
      # @return [String] a useable command to copy a file
      def copy_command_for(source, destination)
        if windows?
          %Q{copy "#{source}" "#{destination}"}.gsub(::File::SEPARATOR, ::File::ALT_SEPARATOR)
        else
         "cp -r #{source} #{destination}"
        end
      end

      # @return [Fixnum or nil]
      def windows?
        Chef::Platform.windows?
      end
    end

    class << self
      include Chef::Artifact::File

      # Return the nexus data bag item. An encrypted data bag item will be used if we are
      # running as Chef Client and a standard data bag item will be used if running as
      # Chef Solo
      #
      # @return [Chef::DataBagItem, Chef::EncryptedDataBagItem]
      def load_nexus_dbi
        if Chef::Config[:solo]
          Chef::DataBagItem.load(DATA_BAG, NEXUS_DBI)
        else
          Chef::EncryptedDataBagItem.load(DATA_BAG, NEXUS_DBI)
        end
      rescue Net::HTTPServerException
        raise EncryptedDataBagNotFound.new(NEXUS_DBI)
      end

      def nexus_config_for(node)
        data_bag_item = load_nexus_dbi

        config = data_bag_item[node.chef_environment] || data_bag_item["*"]
        unless config
          raise EnvironmentNotFound.new(NEXUS_DBI, node.chef_environment)
        end
        config
      end

      # Uses the provided parameters to make a call to the data bag
      # configured Nexus server to have the server tell us what the
      # actual version number is when 'latest' is given.
      # 
      # @param  node [Chef::Node] the node
      # @param  artifact_location [String] a colon-separated Maven identifier string that represents the artifact
      # @param  ssl_verify [Boolean] a boolean to pass through to the NexusCli::RemoteFactory#create method. This
      #   is a TERRIBLE IDEA and you should never want to set this to false!
      # 
      # @example
      #   Chef::Artifact.get_actual_version(node, "com.myartifact:my-artifact:latest:tgz") => "2.0.5"
      #   Chef::Artifact.get_actual_version(node, "com.myartifact:my-artifact:1.0.1:tgz")  => "1.0.1"
      # 
      # @return [String] the version number that latest resolves to or the passed in value
      def get_actual_version(node, artifact_location, ssl_verify=true)
        version = artifact_location.split(':')[2]
        if version.casecmp("latest") == 0
          require 'nexus_cli'
          require 'rexml/document'
          config = nexus_config_for(node)
          remote = NexusCli::RemoteFactory.create(config, ssl_verify)
          REXML::Document.new(remote.get_artifact_info(artifact_location)).elements["//version"].text
        else
          version
        end
      end

      # Downloads a file to disk from the configured Nexus server.
      # 
      # @param  node [Chef::Node] the node
      # @param  source [String] a colon-separated Maven identified string that represents the artifact
      # @param  destination_dir [String] a path to download the artifact to
      #
      # @option options [Boolean] :ssl_verify
      #   a boolean to pass through to the NexusCli::RemoteFactory#create method indicated whether
      #   ssl methods should or should not be verified.
      # 
      # @return [Hash] writes a file to disk and returns a Hash with
      # information about that file. See NexusCli::ArtifactActions#pull_artifact.
      def retrieve_from_nexus(node, source, destination_dir, options = {})
        require 'nexus_cli'
        config = nexus_config_for(node)
        remote = NexusCli::RemoteFactory.create(config, options[:ssl_verify])
        remote.pull_artifact(source, destination_dir)
      end

      
      # Generates a URL that hits the Nexus redirect endpoint which will
      # result in an artifact being downloaded.
      #
      # @example
      #   Chef::Artifact.artifact_download_url_for(node, "com.myartifact:my-artifact:1.0.1:tgz")
      #     => "http://my-nexus:8081/nexus/service/local/artifact/maven/redirect?g=com.myartifact&a=my-artifact&v=1.0.1&e=tgz&r=my_repo"
      #
      # @param  node [Chef::Node]
      # @param  source [String] colon separated Nexus location
      # 
      # @return [String] a URL that can be used to retrieve an artifact
      def artifact_download_url_for(node, source)
        # TODO: Move this method into the nexus-cli
        config = nexus_config_for(node)
        group_id, artifact_id, version, extension = source.split(':')
        query_string = "g=#{group_id}&a=#{artifact_id}&v=#{version}&e=#{extension}&r=#{config['repository']}"
        uri_for_url = URI(config['url'])
        builder = uri_for_url.scheme =~ /https/ ? URI::HTTPS : URI::HTTP
        builder.build(host: uri_for_url.host, port: uri_for_url.port, path: '/nexus/service/local/artifact/maven/redirect', query: query_string).to_s
      end

      # Returns the currently deployed version of an artifact given that artifacts
      # installation directory by reading what directory the 'current' symlink
      # points to.
      # 
      # @param  deploy_to_dir [String] the directory where an artifact is installed
      # 
      # @example
      #   Chef::Artifact.get_current_deployed_version("/opt/my_deploy_dir") => "2.0.65"
      # 
      # @return [String] the currently deployed version of the given artifact
      def get_current_deployed_version(deploy_to_dir)

        current_dir = ::File.join(deploy_to_dir, "current")
        if ::File.exists?(current_dir)
          ::File.basename(readlink(current_dir))
        end
      end
    end
  end
end