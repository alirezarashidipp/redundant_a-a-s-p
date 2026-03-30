from src.config.chat_agent_models import WorkflowState
from src.services.grooming_graph import graph


def create_initial_state(raw_input: str) -> WorkflowState:
    return {
        "raw_input": raw_input,
        "who": None, "what": None, "why": None, "ac_evidence": None,
        "missing_fields": [], "phase1_retries": 0, "last_rejection_reason": None,
        "is_aborted": False, "abort_reason": None,
        "pending_questions": [], "total_tech_questions": 0,
        "tech_notes": [],
        "final_story": None, "feedback_retries": 0, "is_complete": False, "feedback_raw": None,
        "action_required": False, "action_prompt": None, "user_injected_response": None,
        "current_phase": "phase0",
    }


def invoke(state: WorkflowState) -> WorkflowState:
    return graph.invoke(state)
