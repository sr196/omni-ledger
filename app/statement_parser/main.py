import json

import httpx
import pandas as pd

from app.statement_parser.models.Statement import Statement
from utils import clean_server_resources, convert_document

document_path="/Users/shubham/PycharmProjects/omni-ledger/app/statement_parser/data/0036XXXXXXXXXX14_21-07-2026_203.pdf"
server_url="http://127.0.0.1:5001"

doc = convert_document(document=document_path, server_url=server_url)


def normalize_table_with_llm(table_markdown: str) -> Statement:
    prompt = f"""
    You are a financial data extraction engine. Analyze the following table extracted from a financial document.
    If the table contains bank/credit card transactions, extract them into the requested schema.
    If it's an interest rate table, summary box, or reward points table, mark `is_transaction_table` as false.

    TABLE CONTENT:
    {table_markdown}
    """

    # Example using Ollama / vLLM local API with JSON Schema
    response = httpx.post(
        "http://localhost:11434/api/chat",
        json={
            "model": "qwen2.5:14b",  # Or llama3.1:8b / mistral
            "messages": [{"role": "user", "content": prompt}],
            "format": Statement.model_json_schema(),
            "stream": False,
            "options": {"temperature": 0.0}
        },
        timeout=300.0
    )

    output_json = json.loads(response.json()["message"]["content"])
    return Statement.model_validate(output_json)

res = normalize_table_with_llm(doc)
if res.is_transaction_table and res.transactions:
    # Convert list of Pydantic models to DataFrame
    df = pd.DataFrame([t.model_dump() for t in res.transactions])
    print(df.to_string(index=False))
else:
    print("Table was classified as non-transactional or empty.")