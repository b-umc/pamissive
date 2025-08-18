# frozen_string_literal: true

require_relative '../../api/dtools_cloud/dtools'

class NonBlockHTML::Server::Session::Dtools
  attr_reader :name, :opened

  def initialize(session)
    @name = 'DTools'
    @tab = 'dtools'
    @session = session
    @opened = true
    @dashboard = ERB.new(File.read("#{__dir__}/dashboard.html.erb"))
    @content = ERB.new(File.read("#{__dir__}/content.html.erb"))
    @dtools_quote_content = ERB.new(File.read("#{__dir__}/dtools_quote_content.html.erb"))
    @dtools_search_and_jobsites = ERB.new(File.read("#{__dir__}/_dtools_search_and_jobsites.html.erb"))
    @conversation_changed = method(:conversation_changed)
    EventBus.subscribe('missive', 'conversation_changed', @conversation_changed)
  end

  def clicked
    @opened = !@opened
    send_header
    send_message(content) if @opened
  end

  def dashboard
    @dashboard.result(binding)
  end

  def content
    @content.result(binding)
  end

  def quote_content
    ''
  end

  def display_data
    '<div id="dtools_quote_content"></div>'
    # @dtools_content.result(binding)
  end

  def on_close(*)
    EventBus.unsubscribe('missive', 'conversation_changed', @conversation_changed)
  end

  private

  def jobsites
    Missive.jobsites
  end

  def clear_quote
    send_message('<div id="dtools_quote_content"></div>')
  end

  def conversation_changed(args)
    dat = args.first
    return on_close if @session.closed?
    return unless dat[:session] == @session.id

    labels = dat[:labels]
    LOG.debug([:dtools_conversation_changed, @session.closed?, @session.id])
    return unless labels && (site = labels.find { |lab| lab[:is_jobsite] })

    LOG.debug([:fetch_dtools_info, site['name']])
    DTOOLS.dtools_get("Opportunities/GetOpportunities?search=#{site['name']}") do |res|
      LOG.debug([:dtools, res])
      dat = JSON.parse(res.body)
      next clear_quote unless dat
      next clear_quote if dat['opportunities'].empty?

      dat['opportunities'].each do |opp|
        id = opp['id']
        DTOOLS.dtools_get("Quotes/GetQuotes?opportunityId=#{id}") do |quotes|
          qtsdat = JSON.parse(quotes.body)
          next clear_quote unless qtsdat
          next clear_quote if qtsdat.empty?

          LOG.debug([:dtools_quotse_result, qtsdat])
          qtsdat.each do |quot|
            qid = quot['id']
            DTOOLS.dtools_get("Quotes/GetQuote?id=#{qid}") do |quote|
              # LOG.debug([:dtools_quote_result, body.class, body.to_s])
              quote_data = JSON.parse(quote.body)
              next clear_quote unless quote_data
              next clear_quote if quote_data.empty?

              send_message(@dtools_quote_content.result(binding))
              # LOG.debug([:dtools_quote_result, quote_data])
              send_js(quote_listener)
            end
          end
        end
      end
      # Missive.
    end
  end

  def quote_listener
    %(
      var coll = document.getElementsByClassName("collapsible-button");
      for (var i = 0; i < coll.length; i++) {
          coll[i].addEventListener("click", function() {
              this.classList.toggle("active");
              var content = this.nextElementSibling;
              if (content.style.display === "block") {
                  content.style.display = "none";
              } else {
                  content.style.display = "block";
              }
          });
      }
    )
  end

  def send_header
    cls = "box box-collapsable#{' box-collapsable--opened' if @opened}"
    send_message(
      {
        type: :cls,
        id: 'header-box-dtools',
        class: cls
      }.to_json
    )
  end

  def send_message(data)
    @session.send_message(data)
  end

  def send_js(data)
    @session.send_js(data)
  end
end
