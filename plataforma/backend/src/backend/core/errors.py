from fastapi import HTTPException


def openai_error(status_code: int, message: str, error_type: str) -> HTTPException:
    """Constrói um HTTPException cujo `detail` já está no formato OpenAI-compatible
    usado pelos exception handlers registrados em `main.py`: `{"message", "type"}`.
    """
    return HTTPException(status_code=status_code, detail={"message": message, "type": error_type})
