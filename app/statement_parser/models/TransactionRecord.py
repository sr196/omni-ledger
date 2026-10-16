from typing import Optional
from pydantic import BaseModel, Field
from app.statement_parser.models.TransactionType import TransactionType


class TransactionRecord(BaseModel):
    transaction_date: str = Field(description="YYYY-MM-DD format")
    posting_date: Optional[str] = Field(None, description="YYYY-MM-DD format if available")
    description: str = Field(description="Clean merchant/transaction narrative")
    category: Optional[str] = Field(None, description="Inferred high-level category (e.g., Grocery, Fuel, Utility)")
    amount: float = Field(description="Absolute monetary value")
    type: TransactionType = Field(description="DEBIT (expense/withdrawal) or CREDIT (refund/deposit/payment)")
    balance_after_txn: Optional[float] = Field(None, description="Running balance if present")
