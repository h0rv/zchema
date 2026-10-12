"""Run against `zig build run`. Uses only Python's standard library."""
import json
import unittest
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

BASE = "http://127.0.0.1:8080"


def request(path, *, hx=False, method="GET"):
    req = Request(BASE + path, method=method,
                  headers={"HX-Request": "true"} if hx else {})
    try:
        response = urlopen(req, timeout=5)
    except HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read().decode()


class CatalogHTTP(unittest.TestCase):
    def test_page_and_fragment(self):
        for hx in (False, True):
            status, headers, html = request("/?q=HTTP&category=books", hx=hx)
            self.assertEqual(status, 200)
            self.assertIn("text/html", headers["Content-Type"])
            self.assertEqual(headers["Vary"], "HX-Request")
            self.assertEqual(headers["Connection"].lower(), "close")
            self.assertEqual("<html" in html, not hx)
            self.assertIn("HTTP &amp; HTML", html)
            self.assertNotIn("Template inspector", html)

    def test_escaping_and_unicode(self):
        payload = '\"><script>alert(9)</script>&é'
        status, _, html = request("/?" + urlencode({"q": payload}))
        self.assertEqual(status, 200)
        self.assertNotIn(payload, html)
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("&quot;", html)
        self.assertIn("é", html)
        _, _, html = request("/")
        self.assertNotIn("<script>alert(1)</script>", html)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", html)

    def test_json_and_malformed_query(self):
        status, headers, body = request("/api/catalog?q=HTTP+%26+HTML&category=books")
        self.assertEqual(headers["Connection"].lower(), "close")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), [{"name": "HTTP & HTML", "category": "books"}])
        for path in ("/", "/api/catalog"):
            for hx in (False, True):
                status, headers, body = request(path + "?category=invalid", hx=hx)
                self.assertEqual(status, 422)
                self.assertIn("application/problem+json", headers["Content-Type"])
                self.assertIn("category", body)
        status, _, body = request("/api/catalog?q=nothing-matches")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), [])

    def test_routes_and_openapi(self):
        status, _, body = request("/openapi.json")
        self.assertEqual(status, 200)
        spec = json.loads(body)
        self.assertEqual(set(spec["paths"]), {"/api/catalog"})
        operation = spec["paths"]["/api/catalog"]["get"]
        self.assertEqual({p["name"] for p in operation["parameters"]}, {"q", "category"})
        self.assertIn("200", operation["responses"])
        self.assertEqual(request("/docs")[0], 200)
        self.assertEqual(request("/missing")[0], 404)
        self.assertEqual(request("/api/catalog", method="POST")[0], 404)
        status, _, body = request("/", method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, "")


if __name__ == "__main__":
    unittest.main()
