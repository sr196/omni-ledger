from typing import List, Optional
from pydantic import BaseModel, Field

from app.statement_parser.models.TransactionRecord import TransactionRecord


class Statement(BaseModel):
    is_transaction_table: bool = Field(description="Set to false if table is rewards, interest rates, or summary")
    institution_name: Optional[str] = Field(None, description="Bank or card issuer name if detectable")
    account_number_masked: Optional[str] = Field(None, description="Last 4 digits if found")
    transactions: List[TransactionRecord] = Field(default_factory=list)