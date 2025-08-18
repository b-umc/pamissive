# class Missive::Channel::Message

# end

# Name
# * required
# Description	Example
# account*	Account ID. You can find this ID in the custom channel settings.	"fbf74c47-d0a0-4d77-bf3c-2118025d8102"
# subject	Email channel only:
# string	"Hello"
# body	HTML or text string based on channel message type.	"<b>World!</b>"
# from_field	Email channel:
# Object with "address" and "name" keys.

# Text or HTML channel:
# Object with "id", "username" and "name" keys.	{ "address": "philippe@missiveapp.com", "name": "Philippe Lehoux" }


# { "id": "12345", "username": "@missiveapp", "name": "Missive" }
# to_fields	Email channel:
# Array of objects with "address" and "name" keys.

# Text or HTML channel:
# Array of objects with "id", "username" and "name" keys.	

# [{ "address": "philippe@missiveapp.com", "name": "Philippe Lehoux" }]


# [{ "id": "12345", "username": "@missiveapp", "name": "Missive" }]
# cc_fields	Email channel only:
# Array of objects with "address" and "name" keys.	[{ "address": "philippe@missiveapp.com", "name": "Philippe Lehoux" }]
# bcc_fields	Email channel only:
# Array of objects with "address" and "name" keys.	[{ "address": "philippe@missiveapp.com", "name": "Philippe Lehoux" }]
# delivered_at	Message delivery timestamp. If omitted, message is marked as delivered at request time.	1563806347
# attachments	Array containing files, see below for details.	[{ "base64_data": "iVBORw0KGgoAAAANS...", "filename": "logo.png" }]
# external_id	Unique ID used to identify non-email messages (SMS, Instagram DMs, etc).	"some-id-123"
# references	Array of strings for appending to an existing conversation.	["some-reference-123"]
# conversation	Conversation ID string for appending to an existing conversation	"5bb24363-69e5-48ed-80a9-feee988bc953"
# team	Team ID string	Default based on channel sharing settings: Inbox or Team Inbox
# force_team	boolean	false
# organization	Organization ID string	"90beb742-27a3-44cf-95bc-7e5097167c9d"
# add_users	Array of user ID strings	["7343bccf-cf35-4b33-99b0-b1d3c69c5f5c"]
# add_assignees	Array of user ID strings	["7343bccf-cf35-4b33-99b0-b1d3c69c5f5c"]
# conversation_subject	string	"New user!"
# conversation_color	HEX color code or "good" "warning" "danger" string	"#000", "danger"
# add_shared_labels	Array of shared label ID strings	["9825718b-3407-40b8-800d-a27361c86102"
# remove_shared_labels	Array of shared label ID strings	["e4aae78f-e932-40a2-9ece-ed764aa85790"]
# add_to_inbox	boolean	Default based on channel sharing settings: Inbox or Team Inbox
# add_to_team_inbox	boolean	Default based on channel sharing settings: Inbox or Team Inbox
# close	boolean	false