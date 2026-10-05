"""The Acme Shop API for the Flotilla demo: a few JSON endpoints and nothing else."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PRODUCTS = [
    {"id": 1, "name": "Watermelon tumbler", "price": 24.0},
    {"id": 2, "name": "Cantaloupe mug", "price": 18.0},
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = {"/": {"service": "storefront-api", "ok": True},
                "/products": PRODUCTS}.get(self.path)
        self.send_response(200 if body is not None else 404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body or {"error": "not found"}).encode())


HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
