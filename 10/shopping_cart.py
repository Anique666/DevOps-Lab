import os

from flask import Flask, jsonify, request

app = Flask(__name__)

cart = []


@app.get("/cart")
def get_cart():
    return jsonify(cart)


@app.post("/cart")
def add_to_cart():
    item = request.get_json(silent=True)
    if item is None:
        return jsonify({"error": "A JSON request body is required"}), 400
    cart.append(item)
    return jsonify(cart), 201


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 80)))
