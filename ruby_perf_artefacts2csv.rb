require 'uri'
require 'net/http'
require 'openssl'
require 'typhoeus'
require 'json'
require 'circleci_openapi'
require 'open-uri'
require 'csv'
require 'nokogiri'

CircleciOpenapi.configure do |config|
  config.api_key["api_key_header"] = ENV["CIRCLECI_TOKEN"]
  config.debugging = true
end

Typhoeus::Config.verbose = true
default_headers = { "Circle-Token" => ENV["CIRCLECI_TOKEN"] }
project_slug = 'github/akeneo/pim-enterprise-dev' # String | Project slug in the form \`vcs-slug/org-name/repo-name\`. The \`/\` characters may be URL-escaped.
workflow_name = 'nightly' # String | The name of the workflow.
job_name = 'test_back_performance' # String | The name of the job.

pipeline_api = CircleciOpenapi::PipelineApi.new
workflow_api = CircleciOpenapi::WorkflowApi.new
job_api = CircleciOpenapi::JobApi.new
insight_api = CircleciOpenapi::InsightsApi.new

refDate = Date.today

pp_page_token = "AARLwwUg-IYxwbYyEZjHow2EtdFB4OTGv_r1eqtD_raBlgBi6H5WKeJmJ8CrZfI2mQr4gp5MgDyqNn_eAFHISL8-IX606IzJV8ea7iLBbXDAP0T8lRJFRBBUyBzWSpsgDr5YEhwA3oPq"
# job_runs = insight_api.get_project_job_runs_with_http_info(project_slug,workflow_name,job_name)
#
# # pipelines = pipeline_api.list_pipelines_for_project(project_slug) # doesn't work... API is not respected...
# job_api.cancel_job
CSV.open("performance.csv", "wb") do |out|
  out << %w[Date CalculateCompletenessCommandPerformance IndexProductsCommandPerformance ImportNonVariantProductsWithApiPerformance ImportProductModelsWithApiPerformance ImportVariantProductsWithApiPerformance ListProductWithApiPerformance]


  loop do
    query = pp_page_token ? { "page-token" => "#{pp_page_token}" } : {}
    response = Typhoeus::Request.get("https://circleci.com/api/v2/project/#{project_slug}/pipeline?branch=master",
                                     params: query,
                                     headers: default_headers)

    # response = request.run
    pipelineListResponse = JSON.parse(response.body)
    pp_page_token = pipelineListResponse['next_page_token']

    pipelineListResponse['items'].each do |pipeline|

      wfResponse = pipeline_api.list_workflows_by_pipeline_id(pipeline['id'], opts: { "page-token" => pp_page_token })
      throw new Exception("Unhandled job_page_token: #{wfResponse.next_page_token}") if wfResponse.next_page_token
      wfResponse.items.each { |wf|
        wf = workflow_api.get_workflow_by_id(wf.id)
        next unless wf.name == workflow_name
        next if wf.status == "on_hold"

        # jobsResponse  = workflow_api.list_workflow_jobs(wf.id)  # doesn't work... API is not respected...
        response = Typhoeus::Request.get("https://circleci.com/api/v2/workflow/#{wf.id}/job", headers: default_headers)
        jobsResponse = JSON.parse(response.body)
        throw new Exception("Unhandled job_page_token: #{jobsResponse['next_page_token']}") if jobsResponse['next_page_token']

        # end
        jobsResponse['items'].each { |job|
          next unless job_name == job['name']
          next if job['job_number'].nil?
          artifacts = job_api.get_job_artifacts(job['job_number'], project_slug)
          artifacts.items.each { |artifact|
            next unless artifact.path =~ /var\/tests\/phpunit\/phpunit_.*\.xml$/
            response = Typhoeus::Request.get(artifact.url,headers: default_headers, followlocation: true)
            xmlDoc = response.body
            doc = Nokogiri::XML.parse(xmlDoc)
            nodes = doc.xpath("/testsuites/testsuite/testsuite/testsuite")
            out << [job['started_at']] +  [*0..5].map { |i| nodes[i]['time']} + [pp_page_token]
            out.flush
          }
        }
      }
    end
    break unless pp_page_token
  end

end
