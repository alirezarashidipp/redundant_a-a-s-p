from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from src.services import grooming_agent

router = APIRouter (prefix="/grooming", tags=["grooming"])


class StartRequest (BaseModel):
  text: str


@router.post("/start")
def start_grooming (req: StartRequest) -> dict:
  state grooming_agent.create_initial_state(req.text)
  return grooming_agent.invoke(state)


@router.post("/step")
def step grooming(state: dict) -> dict:
  if state.get("is_complete") or state.get("is_aborted"):
    raise HTTPException(status_code=400, detail="Session is already finished.")
  return grooming_agent.invoke(state)
