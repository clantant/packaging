# Rake Task to dynamically create a Jenkins job to model the
# pl:jenkins:uber_build set of tasks in a Matrix job where each cell is an
# individual build to be run. This would be nice if we only had to create one job,
# but alas, we're actually creating three jobs.
# 1) a packaging job that builds the packages
#                     |
#                     V
# 2) a repo creation job that creates repos from those packages
#                     |
#                     V
# 3) (optional) a job to proxy the downstream job passed in via DOWNSTREAM_JOB
#

namespace :pl do
  namespace :jenkins do
    desc "Dynamic Jenkins UBER build: Build all the things with ONE job"
    task :uber_build => "pl:fetch" do
      # If we have a dirty source, bail, because changes won't get reflected in
      # the package builds
      Pkg::Util::Version.fail_on_dirty_source

      # Use JSON to parse the json part of the submission, so we want to fail
      # here also if JSON isn't available
      Pkg::Util.require_library_or_fail 'json'

      # The uber_build.xml.erb file is an XML erb template that will define a
      # job in Jenkins with all of the appropriate tasks
      work_dir           = Pkg::Util::File.mktemp
      template_dir       = File.join(File.dirname(__FILE__), '..', 'templates')
      templates          = ['repo.xml.erb', 'packaging.xml.erb']
      templates << ('downstream.xml.erb') if ENV['DOWNSTREAM_JOB']

      # Generate an XML file for every job configuration erb and attempt to
      # create a jenkins job from that XML config
      templates.each do |t|
        erb_template  = File.join(template_dir, t)
        xml_file = File.join(work_dir, t.gsub('.erb', ''))
        Pkg::Util::File.erb_file(erb_template, xml_file, nil, :binding => Pkg::Config.get_binding)
        job_name  = "#{Pkg::Config.project}-#{t.gsub('.xml.erb', '')}-#{Pkg::Config.build_date}-#{Pkg::Config.ref}"
        puts "Checking for existence of #{job_name}..."
        if Pkg::Util::Jenkins.jenkins_job_exists?(job_name)
          raise "Job #{job_name} already exists on #{Pkg::Config.jenkins_build_host}"
        else
          retry_on_fail(:times => 3) do
            url = Pkg::Util::Jenkins.create_jenkins_job(job_name, xml_file)
            if t == "packaging.xml.erb"
              ENV["PACKAGE_BUILD_URL"] = url
            end
            puts "Verifying job created successfully..."
            unless Pkg::Util::Jenkins.jenkins_job_exists?(job_name)
              raise "Unable to verify Jenkins job, trying again..."
            end
            puts "Jenkins job created at #{url}"
          end
        end
      end
      rm_r work_dir
      packaging_name = "#{Pkg::Config.project}-packaging-#{Pkg::Config.build_date}-#{Pkg::Config.ref}"
      invoke_task("pl:jenkins:trigger_dynamic_job", packaging_name)
    end

    # Task to trigger the jenkins job we just created. This uses a lot of the
    # same logic in jenkins.rake, with different parameters.
    # TODO make all this replicated code a better, more abstract method
    task :trigger_dynamic_job, :name do |t, args|
      name = args.name

      properties = Pkg::Config.config_to_yaml
      bundle = Pkg::Util::Git.git_bundle('HEAD')

      # Create a string of metrics to send to Jenkins for data analysis
      if Pkg::Config.pe_version
        metrics = "#{ENV['USER']}~#{Pkg::Config.version}~#{Pkg::Config.pe_version}~#{Pkg::Config.team}"
      else
        metrics = "#{ENV['USER']}~#{Pkg::Config.version}~N/A~#{Pkg::Config.team}"
      end

      # Construct the parameters, which is an array of hashes we turn into JSON
      parameters = [{ "name" => "BUILD_PROPERTIES", "file"  => "file0" },
                    { "name" => "PROJECT_BUNDLE",   "file"  => "file1" },
                    { "name" => "PROJECT",          "value" => "#{Pkg::Config.project}" },
                    { "name" => "METRICS",          "value" => "#{metrics}" }]

      # Contruct the json string
      json = JSON.generate("parameter" => parameters)

      # The args array that holds  all of the arguments we pass
      # to the curl utility method.
      curl_args =  [
      "-Fname=BUILD_PROPERTIES", "-Ffile0=@#{properties}",
      "-Fname=PROJECT_BUNDLE",   "-Ffile1=@#{bundle}",
      "-Fname=PROJECT",          "-Fvalue=#{Pkg::Config.project}",
      "-Fname=METRICS",          "-Fvalue=#{metrics}",
      "-FSubmit=Build",
      "-Fjson=#{json.to_json}",
      ]

      # Contstruct the job url
      trigger_url = "#{Pkg::Config.jenkins_build_host}/job/#{name}/build"

      if Pkg::Util::Net.curl_form_data(trigger_url, curl_args)
        Pkg::Util::Net.print_url_info("http://#{Pkg::Config.jenkins_build_host}/job/#{name}")
        puts "Your packages will be available at #{Pkg::Config.distribution_server}:#{Pkg::Config.jenkins_repo_path}/#{Pkg::Config.project}/#{Pkg::Config.ref}"
      else
        fail "An error occurred submitting the job to jenkins. Take a look at the preceding http response for more info."
      end

      # Clean up after ourselves
      rm bundle
      rm properties
    end
  end
end

namespace :pe do
  namespace :jenkins do
    desc "Dynamic Jenkins UBER build: Build all the things with ONE job"
    task :uber_build do
      check_var("PE_VER", Pkg::Config.pe_version)
      invoke_task("pl:jenkins:uber_build")
    end
  end
end
