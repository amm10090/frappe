// Copyright (c) 2016, Frappe Technologies and contributors
// For license information, please see license.txt

const REDACTED_MESSAGE = "[THE FOLLOWING CONTENT HAS BEEN REDACTED FOR SECURITY REASONS]";

function decode_mime_header(value) {
	if (!value?.includes("=?")) {
		return value;
	}

	const adjacent_words = value.replace(/(\?=)\s+(=\?)/g, "$1$2");
	return adjacent_words.replace(
		/=\?([^?]+)\?([bq])\?([^?]*)\?=/gi,
		(word, charset, encoding, encoded_text) => {
			try {
				let bytes;
				if (encoding.toLowerCase() === "b") {
					const binary = atob(encoded_text.replace(/\s/g, ""));
					bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
				} else {
					const decoded_bytes = [];
					const normalized_text = encoded_text.replace(/_/g, " ");

					for (let index = 0; index < normalized_text.length; index++) {
						const hex = normalized_text.slice(index + 1, index + 3);
						if (normalized_text[index] === "=" && /^[\da-f]{2}$/i.test(hex)) {
							decoded_bytes.push(parseInt(hex, 16));
							index += 2;
						} else {
							decoded_bytes.push(normalized_text.charCodeAt(index));
						}
					}

					bytes = Uint8Array.from(decoded_bytes);
				}

				return new TextDecoder(charset).decode(bytes);
			} catch {
				return word;
			}
		}
	);
}

function display_decoded_sender(frm) {
	const sender_field = frm.get_field("sender");
	const decoded_sender = decode_mime_header(frm.doc.sender);

	if (!sender_field || !decoded_sender || decoded_sender === frm.doc.sender) {
		return;
	}

	// Change only the rendered control; keep the RFC 2047 value stored in the document.
	sender_field.$input?.val(decoded_sender);
	sender_field.disp_area && $(sender_field.disp_area).text(decoded_sender);
}

function show_redaction_notice(frm) {
	if (frm.doc.redact_message_after_send && frm.doc.message?.includes(REDACTED_MESSAGE)) {
		frm.set_intro("敏感正文已在发送后删除", "orange");
	}
}

frappe.ui.form.on("Email Queue", {
	refresh: function (frm) {
		display_decoded_sender(frm);
		show_redaction_notice(frm);

		if (["Not Sent", "Partially Sent"].includes(frm.doc.status)) {
			let button = frm.add_custom_button("Send Now", function () {
				frappe.call({
					method: "frappe.email.doctype.email_queue.email_queue.send_now",
					args: {
						name: frm.doc.name,
						force_send: true,
					},
					btn: button,
					callback: function () {
						frm.reload_doc();
						if (cint(frappe.sys_defaults.suspend_email_queue)) {
							frappe.show_alert(
								__(
									"Email queue is currently suspended. Resume to automatically send other emails."
								)
							);
						}
					},
				});
			});
		} else if (frm.doc.status == "Error") {
			frm.add_custom_button("Retry Sending", function () {
				frm.call({
					method: "frappe.email.doctype.email_queue.email_queue.retry_sending",
					args: {
						queues: [frm.doc.name],
					},
					callback: function () {
						frm.reload_doc();
						frappe.show_alert({
							message: __(
								"Status Updated. The email will be picked up in the next scheduled run."
							),
							indicator: "green",
						});
					},
				});
			});
		}

		if (frm.doc.__onload?.mute_emails) {
			frm.dashboard.set_headline(
				__("Automatic sending of emails is disabled via site config.")
			);
		}
	},
});
