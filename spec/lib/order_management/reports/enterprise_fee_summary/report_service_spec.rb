require "spec_helper"

require "order_management/reports/enterprise_fee_summary/report_service"
require "order_management/reports/enterprise_fee_summary/parameters"

describe OrderManagement::Reports::EnterpriseFeeSummary::ReportService do
  let!(:shipping_method) do
    create(:shipping_method, name: "Sample Shipping Method", calculator: per_item_calculator(1.0))
  end

  let!(:payment_method) do
    create(:payment_method, name: "Sample Payment Method", calculator: per_item_calculator(2.0))
  end

  let!(:distributor) do
    create(:distributor_enterprise, name: "Sample Distributor").tap do |enterprise|
      payment_method.distributors << enterprise
      shipping_method.distributors << enterprise
    end
  end
  let!(:distributor_fees) do
    [
      create(:enterprise_fee, name: "Included Distributor Fee 1", enterprise: distributor,
                              fee_type: "admin", calculator: per_item_calculator(4.0),
                              tax_category: prepare_tax_category("Sample Distributor Tax")),
      create(:enterprise_fee, name: "Included Distributor Fee 2", enterprise: distributor,
                              fee_type: "sales", calculator: per_item_calculator(8.0),
                              inherits_tax_category: true),
      create(:enterprise_fee, name: "Excluded Distributor Fee", enterprise: distributor,
                              fee_type: "sales", calculator: per_item_calculator(16.0))
    ]
  end

  let!(:producer) { create(:supplier_enterprise, name: "Sample Producer") }
  let!(:producer_fees) do
    [
      create(:enterprise_fee, name: "Excluded Producer Fee", enterprise: producer,
                              fee_type: "admin", calculator: per_item_calculator(32.0)),
      create(:enterprise_fee, name: "Included Producer Fee 1", enterprise: producer,
                              fee_type: "sales", calculator: per_item_calculator(64.0),
                              tax_category: prepare_tax_category("Sample Producer Tax")),
      create(:enterprise_fee, name: "Included Producer Fee 2", enterprise: producer,
                              fee_type: "sales", calculator: per_item_calculator(128.0),
                              inherits_tax_category: true)
    ]
  end

  let!(:coordinator) { create(:enterprise, name: "Sample Coordinator") }
  let!(:coordinator_fees) do
    [
      create(:enterprise_fee, name: "Excluded Coordinator Fee", enterprise: coordinator,
                              fee_type: "admin", calculator: per_item_calculator(256.0)),
      create(:enterprise_fee, name: "Included Coordinator Fee 1", enterprise: coordinator,
                              fee_type: "admin", calculator: per_item_calculator(512.0),
                              tax_category: prepare_tax_category("Sample Coordinator Tax")),
      create(:enterprise_fee, name: "Included Coordinator Fee 2", enterprise: coordinator,
                              fee_type: "sales", calculator: per_item_calculator(1024.0),
                              inherits_tax_category: true)
    ]
  end

  let!(:order_cycle) do
    create(:simple_order_cycle, coordinator: coordinator,
                                coordinator_fees: [coordinator_fees[1], coordinator_fees[2]])
  end

  let!(:product) { create(:product, tax_category: prepare_tax_category("Sample Product Tax")) }

  let!(:variant) do
    prepare_variant(incoming_exchange_fees: [producer_fees[1], producer_fees[2]],
                    outgoing_exchange_fees: [distributor_fees[0], distributor_fees[1]])
  end

  let!(:customer) { create(:customer, name: "Sample Customer") }
  let!(:another_customer) { create(:customer, name: "Another Customer") }

  describe "grouping and sorting of entries" do
    let!(:customer_order) { prepare_completed_order(customer: customer) }
    let!(:second_customer_order) { prepare_completed_order(customer: customer) }
    let!(:other_customer_order) { prepare_completed_order(customer: another_customer) }

    let(:parameters) { OrderManagement::Reports::EnterpriseFeeSummary::Parameters.new }
    let(:service) { described_class.new(parameters, nil) }

    it "groups and sorts entries correctly" do
      totals = service.enterprise_fee_type_totals

      expect(totals.list.length).to eq(16)

      # Data is sorted by the following, in order:
      # * fee_type
      # * enterprise_name
      # * fee_name
      # * customer_name
      # * fee_placement
      # * fee_calculated_on_transfer_through_name
      # * tax_category_name
      # * total_amount

      expected_result = [
        ["Admin", "Sample Coordinator", "Included Coordinator Fee 1", "Another Customer",
         "Coordinator", "All", "Sample Coordinator Tax", "512.00"],
        ["Admin", "Sample Coordinator", "Included Coordinator Fee 1", "Sample Customer",
         "Coordinator", "All", "Sample Coordinator Tax", "1024.00"],
        ["Admin", "Sample Distributor", "Included Distributor Fee 1", "Another Customer",
         "Outgoing", "Sample Coordinator", "Sample Distributor Tax", "4.00"],
        ["Admin", "Sample Distributor", "Included Distributor Fee 1", "Sample Customer",
         "Outgoing", "Sample Coordinator", "Sample Distributor Tax", "8.00"],
        ["Payment Transaction", "Sample Distributor", "Sample Payment Method", "Another Customer",
         nil, nil, nil, "2.00"],
        ["Payment Transaction", "Sample Distributor", "Sample Payment Method", "Sample Customer",
         nil, nil, nil, "4.00"],
        ["Sales", "Sample Coordinator", "Included Coordinator Fee 2", "Another Customer",
         "Coordinator", "All", "Sample Product Tax", "1024.00"],
        ["Sales", "Sample Coordinator", "Included Coordinator Fee 2", "Sample Customer",
         "Coordinator", "All", "Sample Product Tax", "2048.00"],
        ["Sales", "Sample Distributor", "Included Distributor Fee 2", "Another Customer",
         "Outgoing", "Sample Coordinator", "Sample Product Tax", "8.00"],
        ["Sales", "Sample Distributor", "Included Distributor Fee 2", "Sample Customer",
         "Outgoing", "Sample Coordinator", "Sample Product Tax", "16.00"],
        ["Sales", "Sample Producer", "Included Producer Fee 1", "Another Customer",
         "Incoming", "Sample Producer", "Sample Producer Tax", "64.00"],
        ["Sales", "Sample Producer", "Included Producer Fee 1", "Sample Customer",
         "Incoming", "Sample Producer", "Sample Producer Tax", "128.00"],
        ["Sales", "Sample Producer", "Included Producer Fee 2", "Another Customer",
         "Incoming", "Sample Producer", "Sample Product Tax", "128.00"],
        ["Sales", "Sample Producer", "Included Producer Fee 2", "Sample Customer",
         "Incoming", "Sample Producer", "Sample Product Tax", "256.00"],
        ["Shipment", "Sample Distributor", "Sample Shipping Method", "Another Customer",
         nil, nil, "Platform Rate", "1.00"],
        ["Shipment", "Sample Distributor", "Sample Shipping Method", "Sample Customer",
         nil, nil, "Platform Rate", "2.00"]
      ]

      expected_result.each_with_index do |expected_attributes, row_index|
        expect_total_attributes(totals.list[row_index], expected_attributes)
      end
    end
  end

  # Helper methods for example group

  def expect_total_attributes(total, expected_attribute_list)
    actual_attribute_list = [total.fee_type, total.enterprise_name, total.fee_name,
                             total.customer_name, total.fee_placement,
                             total.fee_calculated_on_transfer_through_name, total.tax_category_name,
                             total.total_amount]
    expect(actual_attribute_list).to eq(expected_attribute_list)
  end

  def prepare_tax_category(name)
    create(:tax_category, name: name)
  end

  def default_order_options
    { customer: customer, distributor: distributor, order_cycle: order_cycle,
      shipping_method: shipping_method, variant: variant }
  end

  def prepare_order(options = {})
    target = default_order_options.merge(options)

    create(:order, customer: target[:customer], distributor: target[:distributor],
                   order_cycle: target[:order_cycle],
                   shipping_method: target[:shipping_method]).tap do |order|
      create(:line_item, order: order, variant: target[:variant])
      order.reload
    end
  end

  def prepare_completed_order(options = {})
    order = prepare_order(options)
    complete_order(order, options)
    order.reload
  end

  def complete_order(order, options)
    order.create_shipment!
    create(:payment, state: "checkout", order: order, amount: order.total,
                     payment_method: options[:payment_method] || payment_method)
    order.update_distribution_charge!
    while !order.completed? do break unless order.next! end
  end

  def prepare_variant(options = {})
    variant = create(:variant, product: product, is_master: false)
    exchange = create(:exchange, incoming: true, order_cycle: order_cycle, sender: producer,
                                 receiver: coordinator, variants: [variant])
    attach_enterprise_fees(exchange, options[:incoming_exchange_fees] || [])

    exchange = create(:exchange, incoming: false, order_cycle: order_cycle, sender: coordinator,
                                 receiver: distributor, variants: [variant])
    attach_enterprise_fees(exchange, options[:outgoing_exchange_fees] || [])
    variant
  end

  def attach_enterprise_fees(exchange, enterprise_fees)
    enterprise_fees.each do |enterprise_fee|
      exchange.enterprise_fees << enterprise_fee
    end
  end

  def per_item_calculator(amount)
    Spree::Calculator::PerItem.new(preferred_amount: amount)
  end
end
