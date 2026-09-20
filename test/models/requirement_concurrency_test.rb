require "test_helper"

class RequirementConcurrencyTest < ActiveSupport::TestCase
  include TestSupport::ShoppingRecords

  self.use_transactional_tests = false

  setup do
    @session = create_shopping_session_for_shopping
  end

  teardown do
    Requirement.where(shopping_session_id: @session.id).delete_all
    @session.destroy
  end

  test "the database enforces one active requirement per session and key under genuine concurrent transactions" do
    key = unique_test_value("concurrent-key")
    results = Array.new(2)

    threads = Array.new(2) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Requirement.create!(shopping_session_id: @session.id, requirement_key: key, operator: "eq",
            kind: "hard", value_json: { "value" => i }, value_schema_version: 1, source: "user_explicit",
            confidence: 1.0, importance: 1.0, status: "active")
          results[i] = :ok
        rescue ActiveRecord::RecordNotUnique
          results[i] = :conflict
        end
      end
    end
    threads.each(&:join)

    assert_equal [ :ok, :conflict ].sort, results.sort
    assert_equal 1, Requirement.where(shopping_session_id: @session.id, requirement_key: key, status: "active").count
  end

  test "the recorder service resolves concurrent supersede races to a single active requirement via retry" do
    key = unique_test_value("recorder-race")
    results = Array.new(2)

    threads = Array.new(2) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          recorder = Shopping::RequirementRecorder.new
          payload = requirement_payload(requirement_key: key, value_json: { "value" => i })
          results[i] = recorder.record(shopping_session: @session, requirement: payload)
        end
      end
    end
    threads.each(&:join)

    all = Requirement.where(shopping_session_id: @session.id, requirement_key: key).order(:id).to_a
    active = all.select { |requirement| requirement.status == "active" }

    assert_equal 2, all.length
    assert_equal 1, active.length
    assert_equal "superseded", all.first.status
    assert_equal all.first.id, all.last.supersedes_requirement_id
    assert_equal all.last.id, active.first.id
    assert_equal results.map(&:id).sort, all.map(&:id).sort
  end
end
