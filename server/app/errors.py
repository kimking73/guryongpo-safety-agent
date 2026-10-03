"""공통 에러 형식 { code, message, detail } — 명세 6장

message 는 사용자에게 그대로 보여줘도 되는 한국어.
"""
from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger(__name__)

DEFAULT_MESSAGES = {
    "UNAUTHORIZED": "로그인이 필요합니다. 앱을 다시 시작해 주세요.",
    "FORBIDDEN": "이 기능을 사용할 권한이 없습니다. 초대 코드로 역할을 먼저 받아 주세요.",
    "NOT_FOUND": "요청한 정보를 찾을 수 없습니다.",
    "CONFLICT": "이미 끝난 대피 상황입니다.",
    "INVALID_INVITE": "초대 코드가 올바르지 않거나 만료되었습니다.",
    "VALIDATION_ERROR": "입력값을 확인해 주세요.",
    "STT_FAILED": "음성을 알아듣지 못했습니다. 다시 말씀해 주세요.",
    "AGENT_TIMEOUT": "답변이 늦어지고 있습니다. 잠시 후 다시 시도해 주세요.",
    "UPSTREAM_UNAVAILABLE": "외부 서비스에 연결할 수 없습니다. 잠시 후 다시 시도해 주세요.",
    "INTERNAL": "서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.",
}
STATUS_CODES = {"UNAUTHORIZED": 401, "FORBIDDEN": 403, "NOT_FOUND": 404, "CONFLICT": 409, "INVALID_INVITE": 400,
                "VALIDATION_ERROR": 422, "STT_FAILED": 422,
                "AGENT_TIMEOUT": 504, "UPSTREAM_UNAVAILABLE": 503, "INTERNAL": 500}


class ApiError(Exception):
    def __init__(self, code: str, message: str | None = None, detail: Any = None, status: int | None = None):
        self.code, self.detail = code, detail
        self.message = message or DEFAULT_MESSAGES.get(code, DEFAULT_MESSAGES["INTERNAL"])
        self.status = status or STATUS_CODES.get(code, 500)
        super().__init__(f"{code}: {self.message}")


def body(code: str, message: str | None = None, detail: Any = None) -> dict:
    out = {"code": code, "message": message or DEFAULT_MESSAGES[code]}
    if detail is not None:
        out["detail"] = detail
    return out


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api(_: Request, e: ApiError):
        headers = {"WWW-Authenticate": "Bearer"} if e.status == 401 else None
        return JSONResponse(body(e.code, e.message, e.detail), status_code=e.status, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, e: RequestValidationError):
        detail = [{"loc": list(x.get("loc", [])), "msg": x.get("msg")} for x in e.errors()]
        return JSONResponse(body("VALIDATION_ERROR", detail=detail), status_code=422)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, e: StarletteHTTPException):
        code = {401: "UNAUTHORIZED", 403: "FORBIDDEN", 404: "NOT_FOUND", 409: "CONFLICT", 422: "VALIDATION_ERROR",
                503: "UPSTREAM_UNAVAILABLE"}.get(
            e.status_code, "INTERNAL" if e.status_code >= 500 else "VALIDATION_ERROR")
        return JSONResponse(body(code), status_code=e.status_code)

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, e: Exception):
        log.exception("unhandled error")
        return JSONResponse(body("INTERNAL"), status_code=500)
