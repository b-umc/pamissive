# frozen_string_literal: true

class DTools
  # sync pattern:
  # sync all paginated on load
  # for any updated opportunity, sync the quotes
  # any time any object is updated or created grab the full item.
  # tables should be updated with all columns
  # column types uuid, char varying, numeric, boolean, and timestamp without timezone

  def quote_presented(data)
    LOG.debug([:dtools_quote_presented, data])
    fetch_object_for_endpoint(:quote, data['ObjectId']) do |fetch_result|
      LOG.debug([:quote, :fetch_result, fetch_result])
      store_object_for_endpoint(:quotes, JSON.parse(fetch_result.body)) do |store_result|
        LOG.debug([:quote, :store_result, store_result])
      end
    end
  end

  def opportunity_updated(data)
    LOG.debug([:dtools_opportunity_updated, data])
    add_timeout(method(:sync_timer), 10)
  end

  def opportunity_created(data)
    LOG.debug([:dtools_opportunity_created, data])
    sync_endpoint(:opportunities) do |result|
      LOG.debug([:opportunities, :sync_result, result])
    end
  end

  def opportunity_deleted(data)
    delete_endpoint_row(:opportunities, data['ObjectId'])
    @objects[:opportunities].delete(data['ObjectId'])
  end

  def client_updated(data)
    LOG.debug([:dtools_client_updated, data])
    add_timeout(method(:sync_timer), 10)
  end

  def client_created(data)
    LOG.debug([:dtools_client_created, data])
    sync_endpoint(:clients) do |result|
      LOG.debug([:clients, :sync_result, result])
    end
  end

  def client_deleted(data)
    delete_endpoint_row(:clients, data['ObjectId'])
    @objects[:clients].delete(data['ObjectId'])
  end

  def product_updated(data)
    LOG.debug([:dtools_product_updated, data])
    add_timeout(method(:sync_timer), 10)
  end

  def product_created(data)
    LOG.debug([:dtools_product_created, data])
    sync_endpoint(:products) do |result|
      LOG.debug([:products, :sync_result, result])
    end
  end

  def product_deleted(data)
    delete_endpoint_row(:products, data['ObjectId'])
    @objects[:products].delete(data['ObjectId'])
  end

  def project_updated(data)
    LOG.debug([:dtools_project_updated, data])
    add_timeout(method(:sync_timer), 10)
  end

  def project_created(data)
    LOG.debug([:dtools_project_created, data])
    sync_endpoint(:projects) do |result|
      LOG.debug([:projects, :sync_result, result])
    end
  end

  def project_deleted(data)
    delete_endpoint_row(:projects, data['ObjectId'])
    @objects[:projects].delete(data['ObjectId'])
  end

  def purchase_order_updated(data)
    LOG.debug([:dtools_purchase_order_updated, data])
    add_timeout(method(:sync_timer), 10)
  end

  def purchase_order_created(data)
    LOG.debug([:dtools_purchase_order_created, data])
    sync_endpoint(:purchase_orders) do |result|
      LOG.debug([:purchase_orders, :sync_result, result])
    end
  end

  def purchase_order_deleted(data)
    delete_endpoint_row(:purchase_orders, data['ObjectId'])
    @objects[:purchase_orders].delete(data['ObjectId'])
  end

  def service_contract_updated(data)
    LOG.debug([:dtools_service_contract_updated, data])
    add_timeout(method(:sync_timer), 10)
  end

  def service_contract_created(data)
    LOG.debug([:dtools_service_contract_created, data])
    sync_endpoint(:service_contracts) do |result|
      LOG.debug([:service_contracts, :sync_result, result])
    end
  end

  def service_contract_deleted(data)
    delete_endpoint_row(:service_contracts, data['ObjectId'])
    @objects[:service_contracts].delete(data['ObjectId'])
  end

  def quote_updated(data)
    LOG.debug([:dtools_quote_updated, data])
    add_timeout(method(:sync_timer), 10)
  end

  def quote_created(data)
    LOG.debug([:dtools_quote_created, data])
    sync_endpoint(:quotes) do |result|
      LOG.debug([:quotes, :sync_result, result])
    end
  end

  def quote_deleted(data)
    delete_endpoint_row(:quotes, data['ObjectId'])
    @objects[:quotes].delete(data['ObjectId'])
  end
end
