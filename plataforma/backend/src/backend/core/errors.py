from fastapi import HTTPException


def openai_error(status_code: int, message: str, error_type: str) -> HTTPException:
    """Builds an HTTPException whose `detail` is already in the OpenAI-compatible format
    used by the exception handlers registered in `main.py`: `{"message", "type"}`.
    """
    return HTTPException(status_code=status_code, detail={"message": message, "type": error_type})
