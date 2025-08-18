# frozen_string_literal: true

require 'erb'
# require_relative 'quickbooks_online'
# require_relative 'dtools_cloud'
require_relative 'quickbooks_time'
require_relative 'missive'
JOBS_FOLDER_ID = '0ACOJDv09enpJUk9PVA'

class NonBlockHTML::Server; end

class NonBlockHTML::Server::Session
  include TimeoutInterface
  DETECT_DEVICE = %(function detectDeviceType() {
    const userAgent = navigator.userAgent || navigator.vendor || window.opera;

    // Check for iOS devices
    if (/iPad|iPhone|iPod/.test(userAgent) && !window.MSStream) {
      return "iOS Device";
    }

    // Check for Android devices
    if (/android/i.test(userAgent)) {
      return "Android Device";
    }

    // Check for Windows Phone
    if (/windows phone/i.test(userAgent)) {
      return "Windows Phone";
    }

    // Check for other mobile devices
    if (/mobile/i.test(userAgent)) {
      return "Mobile Device";
    }

    // Check for iPadOS (which uses a desktop-like user agent)
    if (navigator.maxTouchPoints && navigator.maxTouchPoints > 2 && /MacIntel/.test(navigator.platform)) {
      return "iPadOS Device";
    }

    // Default to desktop if no mobile or tablet match
      return "Desktop";
    }

    console.log(detectDeviceType());
  })

  def initialize(session)
    LOG.debug([:new_html_session, session.id])
    @system = {}
    @ws = session.ws
    @session = session
    @ws.message_handler = method(:on_message)
    @ws.close_handler = method(:on_close)
    @drive_location = [false, JOBS_FOLDER_ID]
    @ignore_next = false
    init_state
    category_div
  end

  def google_token
    TOK["google:#{id}"]
  end

  def id
    @session.id
  end

  def closed?
    @ws.closed?
  end

  def on_close(*)
    @system.each_value do |sys|
      sys.send(:on_close) if sys.respond_to?(:on_close)
    end
  end

  def on_message(data, _)
    LOG.debug([:new_msg, @session.id, data[0..1000]])
    data = JSON.parse(data)
    return (@ignore_next = false) if @ignore_next && data['clicked']

    case data['cat']
    when 'mis' then @system['mis'].on_message(data)
    when 'qbo' then @system['qbo'].on_message(data)
    when 'quickbooks_time' then @system['quickbooks_time'].on_message(data)
    when 'ctl' then session_control(data)
    when 'drive' then handle_drive_request(data)
    else
      LOG.debug([:unknown_category_session_request_from_ws])
    end
  end

  def list_drive_folder_contents(folder_id, &callback)
    access_token = google_token.access_token
    query_params = {
      q: "'#{folder_id}' in parents and trashed = false",
      fields: 'nextPageToken, files(id, name, webViewLink, parents, mimeType, iconLink)',
      includeItemsFromAllDrives: 'true',
      supportsAllDrives: 'true'
    }
    query_string = URI.encode_www_form(query_params)
    url = "https://www.googleapis.com/drive/v3/files?#{query_string}"

    headers = {
      'Authorization' => "Bearer #{access_token}",
      'Accept' => 'application/json'
    }

    NonBlockHTTP::Client::ClientSession.new.get(url, { headers: headers }) do |response|
      if response.code == 200
        # LOG.debug([:drive_res, response])
        result = JSON.parse(response.body)
        files = result['files']
        callback.call(files)
      else
        LOG.error("Drive API Error: #{response.code} - #{response.body}")
        callback.call(nil)
      end
    end
  end

  def upload_file_to_drive(file_name, file_content, folder_id, &callback)
    access_token = google_token.access_token

    url = 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true'

    metadata = {
      'name' => file_name,
      'parents' => [folder_id]
    }

    boundary = '-------314159265358979323846'
    delimiter = "\r\n--#{boundary}\r\n"
    close_delimiter = "\r\n--#{boundary}--"

    body = ''.dup
    body << delimiter
    body << "Content-Type: application/json; charset=UTF-8\r\n\r\n"
    body << metadata.to_json
    body << delimiter
    body << "Content-Type: application/octet-stream\r\n\r\n"
    body << file_content
    body << close_delimiter

    headers = {
      'Authorization' => "Bearer #{access_token}",
      'Content-Type' => "multipart/related; boundary=#{boundary}",
      'Content-Length' => body.bytesize.to_s
    }

    NonBlockHTTP::Client::ClientSession.new.post(url, { headers: headers, body: body }) do |response|
      if response.code == 200 || response.code == 201
        callback.call(true)
      else
        LOG.error("Drive API Upload Error: #{response.code} - #{response.body}")
        callback.call(false)
      end
    end
  end

  def folder_html(parent, file, hx_label)
    hx_select = %({"cat": "drive", "action": "multi_select"}})
    hx_click = %({"cat": "drive", "clicked": true, "action":"browse_folder","parentFolderId":#{parent},"folderId":"#{file['id']}"})
    %(
      <div class="list-items" id="file_box" hx-swap-oob="beforeend">
        <div class="selectable">
          <div class="light-box columns">
            <div class="list-item margin-small">
              <input name="selected_files[]" value="#{file['id']}"
                type="checkbox" class="checkmark" ws-send hx-vals='#{hx_select}'
                  hx-trigger="change" hx-include="#checkbox-form" id='checkbox_#{file['id']}'/>
            </div>

            <div class="list-item padding-small column-grow" style="flex-shrink: 1;" ws-send hx-vals='#{hx_click}'>
                📁 #{file['name']}
            </div>

            <i class="icon icon-label margin-small" id="label_#{file['id']}" ws-send hx-trigger="click consume" hx-vals='#{hx_label}'>
              <svg viewBox="0 0 17 17">
                <use xlink:href="#icon-label"></use>
              </svg>
            <div class='list-item padding-small context-menu' id='context-menu-#{file['id']}'></div>
            </i>
          </div>
        </div>
        <div id="file_box_#{file['id']} hx-swap-oob="beforeend"></div>
      </div>
    )
  end

  def file_html(_parent, file, hx_label)
    hx_select = %({"cat": "drive", "action":"multi_select"}})
    %(
      <div class="list-items light-box" id="file_box" hx-swap-oob="beforeend">
      <div class="selectable">
        <div class="columns selectable">
          <div class="list-item margin-small">
            <input name="selected_files[]" value="#{file['id']}"
              type="checkbox" class="checkmark" ws-send hx-vals='#{hx_select}'
                hx-trigger="change" hx-include="#checkbox-form" id='checkbox_#{file['id']}}'/>
          </div>

          <div class="list-item padding-small column-grow" style="flex-shrink: 1;">
            <a class='list-item padding-small' href='#{file['webViewLink']}' target='_blank'>
                <img src='#{file['iconLink']}' alt='#{file['mimeType']}' class='file-icon' /> #{file['name']}
            </a>
          </div>

          <i class="icon icon-label margin-small" id="label_#{file['id']}" ws-send hx-trigger="click consume" hx-vals='#{hx_label}'>
            <svg viewBox="0 0 17 17">
              <use xlink:href="#icon-label"></use>
            </svg>
          <div class='list-item padding-small context-menu' id='context-menu-#{file['id']}'></div>
          </i>
        </div>
        </div>
      </div>
    )
  end

  def render_drive_folder_contents(files, current_folder_id, parent_folder_id = [])
    LOG.debug([:drive_res, current_folder_id, parent_folder_id, files.first])
    sorted_files = files.sort_by do |file|
      [
        file['mimeType'] == 'application/vnd.google-apps.folder' ? 0 : 1,
        file['name'].downcase
      ]
    end
    parent = [current_folder_id] + parent_folder_id
    back_id, *parents = parent_folder_id
    file_links = sorted_files.map do |file|
      hx_label = %({"cat":"drive", "clicked": true,"action":"add_label","file_id":"#{file['id']}"})
      LOG.debug(file)
      if file['mimeType'] == 'application/vnd.google-apps.folder'
        folder_html(parent, file, hx_label)
      else
        file_html(parent, file, hx_label)
      end
    end

    # Back button HTML
    back_button = ''
    unless parent_folder_id.empty?
      back_button = %(
        <div class="list-item padding-small"
                ws-send
                hx-vals='{"cat":"drive", "clicked": true,"action":"browse_folder","folderId":"#{back_id}", "parentFolderId":#{parents}}'>
            ⬅ Back
        </div>
      )
    end

    send_message(%(
      <div id="google_drive_content">
        <input type="text" id="filter-input" placeholder="Filter Jobs..." style="margin: 2px;" />
        <form id="checkbox-form">
          <div class="list-items light-box" id="file_box">
            #{back_button}
          </div>
        </form>
      </div>
    ))
    file_links.each { |fl| send_message(fl)}
  end

  def handle_drive_request(data)
    case data['action']
    when 'browse_folder'
      return send_message(%(<div id="google_drive_content"></div>)) unless @drive_location[0]

      folder_id = data['folderId'] || JOBS_FOLDER_ID
      parent_folder_id = data['parentFolderId'] || []
      list_drive_folder_contents(folder_id) do |files|
        if files
          render_drive_folder_contents(files, folder_id, parent_folder_id)
          # send_message(html_content)
          send_js(filter_js)
        else
          send_message('Error fetching folder contents.')
        end
      end
    when 'add_label'
      LOG.debug(data)
      conv = @system['mis'].state[:conversation]
      options = []
      if conv
        options = conv['labels'].map do |lbl|
          {
            label: lbl['name'],
            value: lbl['id'],
            color: lbl['color']
          }
        end
      end
      click_away
      @ignore_next = true
      send_message(%(

        <div class='padding-small context-menu show'
          id='context-menu-#{data['file_id']}'>
          <div class="light-box">
          <form id="labels-checkbox-form">
            <ul>
            #{
              options.map do |opt|
                %(
                  <li class="list-item" ws-send hx-trigger="click consume" hx-vals='{"cat":"drive", "clicked": true, "action":"context-menu", "id":"#{opt[:value]}"}'>
                    #{opt[:label]}
                  </li>
                )
              end.join("\n")
            }
            </ul>
          </form>
          </div>
        </div>
      ))

    when 'upload_file'
      LOG.debug([:uploading, data['fileName'], data['folderId'].first])
      upload_file_to_drive(data['fileName'], data['fileContent'], data['folderId'])
    end
  end

  def clear_session
    TOK.delete_token(google_token) do
      send_js(
        %(
          localStorage.setItem('session_data', '');
          Missive.storeSet('sessionData', '');
          Missive.reload();
        )
      )
    end
  end

  def session_control(data)
    case data['action']
    when 'logout' then clear_session
    when 'toggle_google_drive' then toggle_google_drive
    when 'toggle_quickbooks_time' then @system['quickbooks_time'].clicked
    when 'click_away' then click_away
    else
      LOG.debug([:unknown_action_session_request_from_ws, data, ])
    end
  end

  def send_js(data)
    @ws.send_js(data)
  end

  def send_message(data)
    @ws.send_message(data)
  end

  def email(default = nil)
    @session&.token&.user_info&.fetch('email', default)
  end

  private

  def click_away
    LOG.debug('click-away')
    send_js(%(
      ct = document.getElementsByClassName('context-menu show');
      for (var i = 0; i < ct.length; i++) {
        ct[i].classList.remove('show')
      };
    ))
  end

  def conversation_change(data)
    LOG.debug([:conversation, data['from'], data.keys])
  end

  def admin?
    @admins ||= ENV.fetch('ADMINISTRATORS', '').split(',')
    @admins.include?(email(''))
  end

  def init_state
    @system['mis'] = Missive.new(self)
    # @system['qbo'] = Quickbooks.new(self)
    @system['quickbooks_time'] = QuickbooksTime.new(self)
    # @system['dtools'] = Dtools.new(self)
    # @system['admin'] = Admin.new(self)
  end

  def filter_js
    js_code = <<-JS

      const socket = event.detail.socketWrapper;
      var filterInput = document.getElementById('filter-input');
      if (filterInput) {
        filterInput.addEventListener('input', function() {
          var filter = filterInput.value.toLowerCase();
          console.log(filter);
          var listItems = document.querySelectorAll(".selectable");
          console.log(listItems);
          listItems.forEach(function(item) {
            var text = item.innerText.toLowerCase();
            if (text.includes(filter)) {
              item.style.display = '';
            } else {
              item.style.display = 'none';
            }
          });
        });
      }

      function uploadFile(file, folderId) {
        var reader = new FileReader();
        reader.onload = function(e) {
          var content = e.target.result;
          // Send the file content to the server for uploading
          uploadFileToServer(file.name, content, folderId);
        };
        reader.readAsArrayBuffer(file);
      }

      function uploadFileToServer(fileName, fileContent, folderId) {
        // Prepare the data to send
        var message = {
          cat: 'drive',
          action: 'upload_file',
          fileName: fileName,
          folderId: folderId,
          fileContent: arrayBufferToBase64(fileContent)
        };
        // Send the data via WebSocket

        socket.send(JSON.stringify(message));
      }

      function arrayBufferToBase64(buffer) {
        var binary = '';
        var bytes = new Uint8Array(buffer);
        var len = bytes.byteLength;
        for (var i = 0; i < len; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
      }

    JS
    send_js(js_code)
  end

  def toggle_google_drive
    @drive_location[0] = !@drive_location[0]
    send_js(%(
      var drawer = document.getElementById('google_drive');
      drawer.classList.#{@drive_location[0] ? 'add' : 'remove'}('box-collapsable--opened');

      var arrow = document.getElementById('google_drive_arrow');
      arrow.style.transform = 'rotate(#{@drive_location[0] ? 90 : 0}deg)'
    ))
    handle_drive_request({ 'action' => 'browse_folder' })
  end

  def category_div
    send_message(%(
      <div id="service-directory">
        <div  id="google_drive" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_google_drive"}' hx-trigger="click">
            <span>
              <i id="google_drive_arrow" class="icon icon-menu-right" style="height: 10px;">
                <svg style="width: 24px; height: 24px;">
                  <use href="#menu-right"></use>
                </svg>
              </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://ssl.gstatic.com/docs/doclist/images/drive_2022q3_32dp.png">
            <a href="https://drive.google.com/drive/shared-drives" target="_blank">
              <span class="service-name">Google Drive<span class="text-xsmall"> (File Storage and Office Tools)</span></span>
            </a>
          </div>
          <div id="google_drive_linked"></div>
          <div id="google_drive_content"></div>
        </div>

        <div id="xio_cloud" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals'{"cat": "ctl", "clicked": true, "action": "toggle_xio_cloud"}' hx-trigger="click">
            <span>
              <i id="google_drive_arrow" class="icon icon-menu-right" style="height: 10px;">
                <svg style="width: 24px; height: 24px;">
                  <use href="#menu-right"></use>
                </svg>
              </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://portal.crestron.io/favicon.ico">
            <a href="https://dealer-portal.crestron.io/" target="_blank">
              <span class="service-name">Crestron XIO<span class="text-xsmall"> (Crestron Remote Management)</span></span>
            </a>
          </div>
        </div>

        <div id="pa_mesh" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_pa_mesh"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://pamesh.ddns.me/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://pamesh.ddns.me" target="_blank">
              <span class="service-name">MeshCentral<span class="text-xsmall"> (Remote Troubleshooting)</span></span>
            </a>
          </div>
          <div id="pa_mesh_content"></div>
        </div>

        <div id="dtools_cloud" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_dtools_cloud"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://d-tools.cloud/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://d-tools.cloud" target="_blank">
              <span class="service-name">D-Tools Cloud<span class="text-xsmall"> (Quoting and Project Management)</span></span>
            </a>
          </div>
          <div id="dtools_cloud_content"></div>
        </div>

        <div id="quickbooks_online" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_quickbooks_online"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://quickbooks.intuit.com/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://quickbooks.intuit.com/ca/sign-in/" target="_blank">
              <span class="service-name">Quickbooks Online<span class="text-xsmall"> (Invoicing and Accounting)</span></span>
            </a>
          </div>
          <div id="quickbooks_online_content"></div>
        </div>

        <div id="quickbooks_time" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_quickbooks_time"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://tsheets.intuit.com/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://tsheets.intuit.com" target="_blank">
              <span class="service-name">Quickbooks Time<span style class="text-xsmall"> (QuickbooksTime Time Tracking)</span></span>
            </a>
          </div>
          <div id="quickbooks_time_content"></div>
        </div>

        <div id="unifi_ui" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_unifi_ui"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://unifi.ui.com/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://unifi.ui.com" target="_blank">
              <span class="service-name">unifi.ui.com<span class="text-xsmall"> (Current Clients)</span></span>
            </a>
          </div>
          <div id="unifi_ui_content"></div>
        </div>

        <div id="unifi_paramount" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_unifi_paramount"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://unifi.paramountautomation.com/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://unifi.paramountautomation.com" target="_blank">
              <span class="service-name">Unifi Paramount<span class="text-xsmall"> (Legacy Networks)</span></span>
            </a>
          </div>
          <div id="unifi_paramount_content"></div>
        </div>

        <div id="paramount_unms" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_paramount_unms"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://paramountautomation.unmsapp.com/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://paramountautomation.unmsapp.com" target="_blank">
              <span class="service-name">UNMS Paramount<span class="text-xsmall"> (Obselete Networks)</span></span>
            </a>
          </div>
          <div id="unms_paramount_content"></div>
        </div>

        <div id="app_ovrc" class="box box-collapsable padding-small">
          <div class="columns-middle" ws-send hx-vals='{"cat": "ctl", "clicked": true, "action": "toggle_app_ovrc"}' hx-trigger="click">
            <span>
            <i class="icon icon-menu-right" style="height: 10px;">
              <svg style="width: 24px; height: 24px;">
                <use href="#menu-right" />
              </svg>
            </i>
            </span>
            <img class="margin-right-small" style="width: 18px; height: 18px;" src="https://ovrc.com/favicon.ico" onerror="this.onerror=null; this.src='default-icon.png'">
            <a href="https://app.ovrc.com" target="_blank">
              <span class="service-name">OVRC<span class="text-xsmall"> (Power Management)</span></span>
            </a>
          </div>
          <div id="unms_paramount_content"></div>
        </div>
      </div>
    ))
  end
end
