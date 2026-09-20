module Search
  # Thin ActiveJob wrapper so catalog indexing can be scheduled/enqueued like any other
  # background unit of work. All indexing behavior lives in Search::CatalogIndexer;
  # this job owns no logic of its own beyond invoking it.
  class CatalogIndexingJob < ApplicationJob
    queue_as :default

    def perform(page_limit: Catalog::ProductReader::MAX_LIMIT)
      Search::CatalogIndexer.new.call(page_limit: page_limit)
    end
  end
end
