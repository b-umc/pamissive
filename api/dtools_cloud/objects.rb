# frozen_string_literal: true

class DTools
  module Objects
    PATHS = {
      change_orders: 'ChangeOrders/GetChangeOrders',
      clients: 'Clients/GetClients',
      opportunities: 'Opportunities/GetOpportunities',
      products: 'Products/GetProducts',
      projects: 'Projects/GetProjects',
      purchase_orders: 'PurchaseOrders/GetPurchaseOrders',
      quotes: 'Quotes/GetQuotes',
      quote: 'Quotes/GetQuote',
      service_contracts: 'ServiceContracts/GetServiceContracts',
      time_entries: 'TimeEntries/GetTimeEntries'
    }.freeze

    INIT_LOAD = %i[
      opportunities clients products projects
      purchase_orders service_contracts quotes
    ].freeze

    PAGINATED = %i[
      opportunities clients products projects
      purchase_orders service_contracts
    ].freeze

    ENDPOINT_CONTAINERS = {
      change_orders: 'changeOrders',
      clients: 'clients',
      opportunities: 'opportunities',
      products: 'products',
      projects: 'projects',
      purchase_orders: 'purchaseOrders',
      quotes: 'quotes',
      service_contracts: 'serviceContracts'
    }.freeze

    ENDPOINT_TABLE_KEYS = {
      opportunities: %w[
        id type clientId clientName clientNumber name number
        buildingType projectType quoteType quoteTemplate
        systemState stageGroup stage priority price servicePrice
        servicePriceInterval budget probability owner projectArea
        fulfillmentLocation estimatedCloseDate actualCloseDate
        estimatedProjectStartDate estimatedProjectEndDate
        leadSource lostReason lostDescription createdDate
        modifiedDate isArchived billingAddress siteAddress
        contacts resources files quoteIds
      ],
      # opportunities: %w[
      #   id type clientId clientName clientNumber name number
      #   systemState stageGroup stage priority price servicePrice
      #   servicePriceInterval budget probability owner
      #   estimatedCloseDate actualCloseDate createdDate
      #   modifiedDate isArchived last_sync_time
      # ],
      clients: %w[
        id last_sync_time type name number contactName email
        phone owner createdDate modifiedDate isActive
      ],
      products: %w[
        id name brand model partNumber shortDescription
        description category keywords defaultQuantity
        sellUnit isLengthBased lengthName length msrp
        unitCost unitPrice margin markup costPerLength
        pricePerLength isTaxable tax supplier system
        phase upcBarcode eanBarcode itfBarcode
        isDiscontinued isClientSupplied createdDate
        modifiedDate isActive images specifications
        laborItems accessories last_sync_time
      ],
      projects: %w[
        id clientId clientName clientNumber name
        number systemState stageGroup stage priority
        price projectManager completedDate createdDate
        modifiedDate isArchived last_sync_time
      ],
      purchase_orders: %w[
        id supplier number status productCount total
        orderedDate receivedDate createdDate
        modifiedDate isArchived last_sync_time
      ],
      service_contracts: %w[
        id clientId clientName clientNumber
        projectId projectName projectNumber
        name number status pricePerMonth startDate
        endDate paymentDueDate canceledDate
        createdDate modifiedDate last_sync_time
      ],
      quotes: %w[
        id opportunityId name number version
        systemState state price servicePrice
        servicePriceInterval isIncludedInTotal
        projectArea fulfillmentLocation
        isIgnoreItemLaborItems
        serviceContractEstimatedStartDateType
        serviceContractEstimatedStartDate
        serviceContractEstimatedStartDateDays
        isServicePlansDeclined isServiceQuote
        validUntilDate acceptedDate createdDate
        modifiedDate projectDescription
        serviceContractDescription files planViews
        locations systems phases laborTypes lengths
        discounts alternateSets items adjustments
        taxSettings taxes paymentTerms servicePlans
      ]
    }.freeze

    ENDPOINT_TABLE_COLUMNS = {
      opportunities: %w[
        id type client_id client_name client_number name
        number building_type project_type quote_type
        quote_template system_state stage_group stage
        priority price service_price service_price_interval
        budget probability owner project_area
        fulfillment_location estimated_close_date
        actual_close_date estimated_project_start_date
        estimated_project_end_date lead_source lost_reason
        lost_description created_date modified_date
        is_archived billing_address site_address
        contacts resources files last_sync_time
      ],
      # opportunities: %w[
      #   id type client_id client_name client_number name number
      #   system_state stage_group stage priority price service_price
      #   service_price_interval budget probability owner
      #   estimated_close_date actual_close_date created_date
      #   modified_date is_archived last_sync_time
      # ],
      clients: %w[
        id type name number contact_name email
        phone owner created_date modified_date is_active last_sync_time
      ],
      products: %w[
        id name brand model part_number short_description
        description category keywords default_quantity
        sell_unit is_length_based length_name length msrp
        unit_cost unit_price margin markup cost_per_length
        price_per_length is_taxable tax supplier system phase
        upc_barcode ean_barcode itf_barcode is_discontinued
        is_client_supplied created_date modified_date
        is_active images specifications labor_items
        accessories last_sync_time
      ],
      projects: %w[
        id client_id client_name client_number name
        number system_state stage_group stage priority
        price project_manager completed_date created_date
        modified_date is_archived last_sync_time
      ],
      purchase_orders: %w[
        id supplier number status product_count total
        ordered_date received_date created_date
        modified_date is_archived last_sync_time
      ],
      service_contracts: %w[
        id client_id client_name client_number
        project_id project_name project_number name
        number status price_per_month start_date
        end_date payment_due_date canceled_date
        created_date modified_date last_sync_time
      ],
      quotes: %w[
        id opportunity_id name number version
        system_state state price service_price
        service_price_interval is_included_in_total
        project_area fulfillment_location
        is_ignore_item_labor_items
        service_contract_estimated_start_date_type
        service_contract_estimated_start_date
        service_contract_estimated_start_date_days
        is_service_plans_declined is_service_quote
        valid_until_date accepted_date created_date
        modified_date project_description
        service_contract_description files
        plan_views locations systems phases
        labor_types lengths discounts alternate_sets
        items adjustments tax_settings taxes
        payment_terms service_plans
      ]
    }.freeze

    ENDPOINT_CONFLICTS = {
      opportunities: %(
         id = EXCLUDED.id,
         type = EXCLUDED.type,
         client_id = EXCLUDED.client_id,
         client_name = EXCLUDED.client_name,
         client_number = EXCLUDED.client_number,
         name = EXCLUDED.name,
         number = EXCLUDED.number,
         building_type = EXCLUDED.building_type,
         project_type = EXCLUDED.project_type,
         quote_type = EXCLUDED.quote_type,
         quote_template = EXCLUDED.quote_template,
         system_state = EXCLUDED.system_state,
         stage_group = EXCLUDED.stage_group,
         stage = EXCLUDED.stage,
         priority = EXCLUDED.priority,
         price = EXCLUDED.price,
         service_price = EXCLUDED.service_price,
         service_price_interval = EXCLUDED.service_price_interval,
         budget = EXCLUDED.budget,
         probability = EXCLUDED.probability,
         owner = EXCLUDED.owner,
         project_area = EXCLUDED.project_area,
         fulfillment_location = EXCLUDED.fulfillment_location,
         estimated_close_date = EXCLUDED.estimated_close_date,
         actual_close_date = EXCLUDED.actual_close_date,
         estimated_project_start_date = EXCLUDED.estimated_project_start_date,
         estimated_project_end_date = EXCLUDED.estimated_project_end_date,
         lead_source = EXCLUDED.lead_source,
         lost_reason = EXCLUDED.lost_reason,
         lost_description = EXCLUDED.lost_description,
         created_date = EXCLUDED.created_date,
         modified_date = EXCLUDED.modified_date,
         is_archived = EXCLUDED.is_archived,
         billing_address = EXCLUDED.billing_address,
         site_address = EXCLUDED.site_address,
         contacts = EXCLUDED.contacts,
         resources = EXCLUDED.resources,
         files = EXCLUDED.files,
         quote_ids = EXCLUDED.quote_ids,
         last_sync_time = EXCLUDED.last_sync_time
      ),
      # opportunities: %(
      #   type = EXCLUDED.type,
      #   client_id = EXCLUDED.client_id,
      #   client_name = EXCLUDED.client_name,
      #   client_number = EXCLUDED.client_number,
      #   name = EXCLUDED.name,
      #   number = EXCLUDED.number,
      #   system_state = EXCLUDED.system_state,
      #   stage_group = EXCLUDED.stage_group,
      #   stage = EXCLUDED.stage,
      #   priority = EXCLUDED.priority,
      #   price = EXCLUDED.price,
      #   service_price = EXCLUDED.service_price,
      #   service_price_interval = EXCLUDED.service_price_interval,
      #   budget = EXCLUDED.budget,
      #   probability = EXCLUDED.probability,
      #   owner = EXCLUDED.owner,
      #   estimated_close_date = EXCLUDED.estimated_close_date,
      #   actual_close_date = EXCLUDED.actual_close_date,
      #   created_date = EXCLUDED.created_date,
      #   modified_date = EXCLUDED.modified_date,
      #   is_archived = EXCLUDED.is_archived,
      #   last_sync_time = EXCLUDED.last_sync_time
      # ),
      clients: %(
        last_sync_time = EXCLUDED.last_sync_time,
        type = EXCLUDED.type,
        name = EXCLUDED.name,
        number = EXCLUDED.number,
        contact_name = EXCLUDED.contact_name,
        email = EXCLUDED.email,
        phone = EXCLUDED.phone,
        owner = EXCLUDED.owner,
        created_date = EXCLUDED.created_date,
        modified_date = EXCLUDED.modified_date,
        is_active = EXCLUDED.is_active;
      ),
      products: %(
        name = EXCLUDED.name,
        brand = EXCLUDED.brand,
        model = EXCLUDED.model,
        part_number = EXCLUDED.part_number,
        short_description = EXCLUDED.short_description,
        description = EXCLUDED.description,
        category = EXCLUDED.category,
        keywords = EXCLUDED.keywords,
        default_quantity = EXCLUDED.default_quantity,
        sell_unit = EXCLUDED.sell_unit,
        is_length_based = EXCLUDED.is_length_based,
        length_name = EXCLUDED.length_name,
        length = EXCLUDED.length,
        msrp = EXCLUDED.msrp,
        unit_cost = EXCLUDED.unit_cost,
        unit_price = EXCLUDED.unit_price,
        margin = EXCLUDED.margin,
        markup = EXCLUDED.markup,
        cost_per_length = EXCLUDED.cost_per_length,
        price_per_length = EXCLUDED.price_per_length,
        is_taxable = EXCLUDED.is_taxable,
        tax = EXCLUDED.tax,
        supplier = EXCLUDED.supplier,
        system = EXCLUDED.system,
        phase = EXCLUDED.phase,
        upc_barcode = EXCLUDED.upc_barcode,
        ean_barcode = EXCLUDED.ean_barcode,
        itf_barcode = EXCLUDED.itf_barcode,
        is_discontinued = EXCLUDED.is_discontinued,
        is_client_supplied = EXCLUDED.is_client_supplied,
        created_date = EXCLUDED.created_date,
        modified_date = EXCLUDED.modified_date,
        is_active = EXCLUDED.is_active,
        images = EXCLUDED.images,
        specifications = EXCLUDED.specifications,
        labor_items = EXCLUDED.labor_items,
        accessories = EXCLUDED.accessories,
        last_sync_time = EXCLUDED.last_sync_time
      ),
      projects: %(
        client_id = EXCLUDED.client_id,
        client_name = EXCLUDED.client_name,
        client_number = EXCLUDED.client_number,
        name = EXCLUDED.name,
        number = EXCLUDED.number,
        system_state = EXCLUDED.system_state,
        stage_group = EXCLUDED.stage_group,
        stage = EXCLUDED.stage,
        priority = EXCLUDED.priority,
        price = EXCLUDED.price,
        project_manager = EXCLUDED.project_manager,
        completed_date = EXCLUDED.completed_date,
        created_date = EXCLUDED.created_date,
        modified_date = EXCLUDED.modified_date,
        is_archived = EXCLUDED.is_archived,
        last_sync_time = EXCLUDED.last_sync_time
      ),
      purchase_orders: %(
        supplier = EXCLUDED.supplier,
        number = EXCLUDED.number,
        status = EXCLUDED.status,
        product_count = EXCLUDED.product_count,
        total = EXCLUDED.total,
        ordered_date = EXCLUDED.ordered_date,
        received_date = EXCLUDED.received_date,
        created_date = EXCLUDED.created_date,
        modified_date = EXCLUDED.modified_date,
        is_archived = EXCLUDED.is_archived,
        last_sync_time = EXCLUDED.last_sync_time
      ),
      service_contracts: %(
        client_id = EXCLUDED.client_id,
        client_name = EXCLUDED.client_name,
        client_number = EXCLUDED.client_number,
        project_id = EXCLUDED.project_id,
        project_name = EXCLUDED.project_name,
        project_number = EXCLUDED.project_number,
        name = EXCLUDED.name,
        number = EXCLUDED.number,
        status = EXCLUDED.status,
        price_per_month = EXCLUDED.price_per_month,
        start_date = EXCLUDED.start_date,
        end_date = EXCLUDED.end_date,
        payment_due_date = EXCLUDED.payment_due_date,
        canceled_date = EXCLUDED.canceled_date,
        created_date = EXCLUDED.created_date,
        modified_date = EXCLUDED.modified_date,
        last_sync_time = EXCLUDED.last_sync_time
      ),
      quotes: %(
        opportunity_id = EXCLUDED.opportunity_id,
        name = EXCLUDED.name,
        number = EXCLUDED.number,
        version = EXCLUDED.version,
        system_state = EXCLUDED.system_state,
        state = EXCLUDED.state,
        price = EXCLUDED.price,
        service_price = EXCLUDED.service_price,
        service_price_interval = EXCLUDED.service_price_interval,
        is_included_in_total = EXCLUDED.is_included_in_total,
        project_area = EXCLUDED.project_area,
        fulfillment_location = EXCLUDED.fulfillment_location,
        is_ignore_item_labor_items = EXCLUDED.is_ignore_item_labor_items,
        service_contract_estimated_start_date_type = EXCLUDED.service_contract_estimated_start_date_type,
        service_contract_estimated_start_date = EXCLUDED.service_contract_estimated_start_date,
        service_contract_estimated_start_date_days = EXCLUDED.service_contract_estimated_start_date_days,
        is_service_plans_declined = EXCLUDED.is_service_plans_declined,
        is_service_quote = EXCLUDED.is_service_quote,
        valid_until_date = EXCLUDED.valid_until_date,
        accepted_date = EXCLUDED.accepted_date,
        created_date = EXCLUDED.created_date,
        modified_date = EXCLUDED.modified_date,
        project_description = EXCLUDED.project_description,
        service_contract_description = EXCLUDED.service_contract_description,
        files = EXCLUDED.files,
        plan_views = EXCLUDED.plan_views,
        locations = EXCLUDED.locations,
        systems = EXCLUDED.systems,
        phases = EXCLUDED.phases,
        labor_types = EXCLUDED.labor_types,
        lengths = EXCLUDED.lengths,
        discounts = EXCLUDED.discounts,
        alternate_sets = EXCLUDED.alternate_sets,
        items = EXCLUDED.items,
        adjustments = EXCLUDED.adjustments,
        tax_settings = EXCLUDED.tax_settings,
        taxes = EXCLUDED.taxes,
        payment_terms = EXCLUDED.payment_terms,
        service_plans = EXCLUDED.service_plans
      )
    }.freeze

    ENDPOINT_QUERY_KEYWORDS = {
      change_orders: %i[projectId],
      clients: %i[
        types owners fromCreatedDate toCreatedDate
        fromModifiedDate toModifiedDate includeInactive
        includeTotalCount search sort page pageSize
      ],
      opportunities: %i[
        types clientIds stageGroups stages
        priorities owners fromEstimatedCloseDate
        toEstimatedCloseDate fromActualCloseDate
        toActualCloseDate fromCreatedDate
        toCreatedDate fromModifiedDate toModifiedDate
        includeArchived includeTotalCount search
        sort page pageSize
      ],
      products: %i[
        brands categories suppliers fromCreatedDate
        fromCreatedDate toCreatedDate toCreatedDate
        fromModifiedDate toModifiedDate
        includeInactive includeTotalCount
        search sort page pageSize
      ],
      projects: %i[
        clientIds stageGroups stages priorities
        projectManagers fromCompletedDate fromCompletedDate
        toCompletedDate toCompletedDate fromCreatedDate
        fromCreatedDate toCreatedDate toCreatedDate
        fromModifiedDate toModifiedDate
         includeArchived includeTotalCount
        search sort page pageSize
      ],
      purchase_orders: %i[
        suppliers projectIds statuses fromOrderedDate
        fromOrderedDate toOrderedDate toOrderedDate
        fromReceivedDate fromReceivedDate toReceivedDate
        toReceivedDate fromCreatedDate fromCreatedDate
        toCreatedDate toCreatedDate
        fromModifiedDate toModifiedDate 
        includeArchived includeTotalCount search
        sort page pageSize
      ],
      quotes: %i[opportunityId],
      quote: %i[id],
      service_contracts: %i[
        clientIds projectIds fromStartDate toStartDate
        fromEndDate toEndDate fromPaymentDueDate
        toPaymentDueDate fromCanceledDate toCanceledDate
        fromCreatedDate toCreatedDate fromModifiedDate
        toModifiedDate includeTotalCount search
        sort page pageSize
      ]
    }.freeze
  end
end
