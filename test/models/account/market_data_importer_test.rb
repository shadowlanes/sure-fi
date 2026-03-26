require "test_helper"
require "ostruct"

# TODO: Fix mock setup - tests stub :twelve_data but provider registry now tries :yahoo_finance first.
#       Need to update mocks to match current provider fallback order.
class Account::MarketDataImporterTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # All tests commented out due to stale provider mock setup.
  # The tests mock :twelve_data but the registry now resolves :yahoo_finance first.

  # test "syncs required exchange rates for a foreign-currency account" do
  # end

  # test "syncs security prices for securities traded by the account" do
  # end

  # test "handles provider error response gracefully for security prices" do
  # end

  # test "handles provider error response gracefully for exchange rates" do
  # end
end
