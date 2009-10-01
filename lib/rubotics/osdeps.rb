require 'tempfile'
module Rubotics
    class OSDependencies
        def self.load(file)
            OSDependencies.new(YAML.load(File.read(file)))
        end

        attr_reader :definitions
        def initialize(defs = Hash.new)
            @definitions = defs.to_hash
        end

        def merge(info)
            @definitions = definitions.merge(info.definitions)
        end

        def operating_system
            if File.exists?('/etc/debian_version')
                codename = File.read('/etc/debian_version').chomp
                ['debian', codename]
            else
                raise "Unknown operating system"
            end
        end

        GAIN_ROOT_ACCESS = <<-EOSCRIPT
        if test `id -u` != "0"; then
            exec sudo /bin/bash $0 "$@"
        
        fi
        EOSCRIPT

        OS_PACKAGE_INSTALL = {
            'debian' => 'apt-get install %s'
        }

        def generate_os_script(dependencies)
            os_name, os_version = operating_system
            shell_snippets = ""
            os_packages    = []
            dependencies.each do |name|
                dep_def = definitions[name]
                if !dep_def
                    raise ArgumentError, "the OS dependency #{name} is not defined"
                elsif !dep_def[os_name]
                    raise ArgumentError, "no data for installing the OS dependency #{name} on #{os_name} #{os_version}"
                end

                data = dep_def[os_name]
                if data.kind_of?(Hash)
                    data = data[os_version]
                    if !data
                        raise "no information for installing the OS dependency #{name} on this specific version of #{os_name} (#{os_version})"
                    end
                end

                if data.respond_to?(:to_ary)
                    os_packages.concat data.to_ary
                elsif data.to_str =~ /\w+/
                    os_packages << data.to_str
                else
                    shell_snippets << "\n" << data << "\n"
                end
            end

            "#! /bin/bash\n" +
            GAIN_ROOT_ACCESS + "\n" +
                (OS_PACKAGE_INSTALL[os_name] % [os_packages.join(" ")]) +
                "\n" + shell_snippets
        end

        def partition_packages(package_set)
            package_set = package_set.to_set
            osdeps, gems = [], []
            package_set.to_set.each do |name|
                pkg_def = definitions[name]
                if !pkg_def
                    raise ArgumentError, "the OS dependency #{name} is not defined"
                end

                if pkg_def.respond_to?(:to_str)
                    case(pkg_def.to_str)
                    when "gem" then
                        gems << name
                    else
                        raise "unknown OS-independent package management type #{pkg_def}"
                    end
                else
                    osdeps << name
                end
            end
            return osdeps, gems
        end

        def install(packages)
            osdeps, gems = partition_packages(packages)

            # Ideally, we would feed the OS dependencies to rosdep.
            # Unfortunately, this is C++ code and I don't want to install the
            # whole ROS stack just for rosdep ...
            #
            # So, for now, reimplement rosdep by ourselves. Given how things
            # are done, this is actually not so hard.
            shell_script = generate_os_script(osdeps)
            if Rubotics.verbose
                STDERR.puts "Installing non-ruby OS dependencies with"
                STDERR.puts shell_script
            end

            STDERR.puts "rubotics: installing OS dependencies"
            File.open('osdeps.sh', 'w') do |file|
                file.write shell_script
            end
            Autobuild::Subprocess.run 'rubotics', 'osdeps', 'bash', './osdeps.sh'
            FileUtils.rm_f 'osdeps.sh'

            # Now install the gems
            if !gems.empty?
                if Rubotics.verbose
                    STDERR.puts "Installing rubygems dependencies with"
                    STDERR.puts "gem install #{gems.join(" ")}"
                end
                STDERR.puts "rubotics: installing RubyGems dependencies"
                Autobuild::Subprocess.run 'rubotics', 'osdeps', 'gem', 'install', *gems
            end
        end
    end
end
