# Copyright (c) 2017, Frappe Technologies and Contributors
# License: MIT. See LICENSE
from unittest.mock import patch

import frappe
from frappe.tests import IntegrationTestCase
from frappe.utils import nowdate


class TestLetterHead(IntegrationTestCase):
	def test_auto_image(self):
		letter_head = frappe.get_doc(
			doctype="Letter Head", letter_head_name="Test", source="Image", image="/public/test.png"
		).insert()

		# test if image is automatically set
		self.assertTrue(letter_head.image in letter_head.content)

	def test_render_preview_uses_hook_context(self):
		from frappe.printing.doctype.letter_head.letter_head import render_preview

		letter_head = frappe.get_doc(
			doctype="Letter Head",
			letter_head_name="Preview Test",
			source="HTML",
			content=(
				"<h1>{{ doc.company }}</h1>"
				"<div>{{ doc.doctype }}</div>"
				"<strong>{{ doc.name }}</strong>"
				"<time>{{ doc.posting_date }}</time>"
			),
		).insert()

		original_get_hooks = frappe.get_hooks

		def get_hooks(hook_name=None, *args, **kwargs):
			if hook_name == "get_letter_head_preview_context":
				return [f"{__name__}.get_test_letter_head_preview_context"]
			return original_get_hooks(hook_name, *args, **kwargs)

		with patch("frappe.get_hooks", side_effect=get_hooks):
			preview = render_preview(letter_head.name, "content")

		self.assertNotIn("{{", preview)
		self.assertIn("Test Company", preview)
		self.assertIn("Sales Invoice", preview)
		self.assertIn("PREVIEW", preview)
		self.assertIn(nowdate(), preview)

	def test_rendering_modified_content_requires_write_permission(self):
		from frappe.printing.doctype.letter_head.letter_head import render_preview

		letter_head = frappe.get_doc(
			doctype="Letter Head",
			letter_head_name="Preview Permission Test",
			source="HTML",
			content="<p>Stored content</p>",
		).insert()

		with patch.object(letter_head.__class__, "check_permission") as check_permission:
			render_preview(letter_head.name, "content", "<p>Modified content</p>")

		check_permission.assert_any_call("read")
		check_permission.assert_any_call("write")


def get_test_letter_head_preview_context(_doc):
	return {"doctype": "Sales Invoice", "company": "Test Company"}
