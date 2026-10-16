from xml.dom.minidom import Document

import requests
import time
from docling.service_client import DoclingServiceClient
from docling.datamodel.service.options import ConvertDocumentsOptions
from docling_core.types import DoclingDocument


def clean_server_resources(server_url: str) -> None:
    """
    Clears accumulated results and converters from the Docling server's memory,
    then pauses briefly to let the server stabilize before the next request.
    """
    try:
        requests.post(f"{server_url}/v1/clear/results")
        requests.post(f"{server_url}/v1/clear/converters")
        print("Cleared Docling server resources.")
    except requests.RequestException as e:
        print(f"Warning: Failed to clear server resources: {e}")
    time.sleep(10)

def convert_document(server_url: str, document: str) -> str:
    with DoclingServiceClient(url=server_url) as client:
        # Offload the heavy OCR/VLM processing to the server
        result = client.convert(
            source=document,
            # The client handles the request and reconstructs the DoclingDocument natively
            options=ConvertDocumentsOptions(to_formats=["md"], image_export_mode="placeholder", do_ocr=False,
                                            force_ocr=False, table_mode="accurate")
        )

    return result.document.export_to_markdown()