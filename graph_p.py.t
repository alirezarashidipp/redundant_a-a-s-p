import yaml
import sys
from pathlib import Path
from typing import Literal
from pydantic import BaseModel, Field
from langgraph.graph import StateGraph, START, END

from state import WorkflowState, ExtractorOutput, ValidatorOutput, TechQuestionsOutput
from llm_client import StructuredLLMClient

# ---------------------------------------------------------
# Configuration Loading & Path Resolution
# ---------------------------------------------------------
CURRENT_DIR = Path(__file__).parent.absolute()
PROMPTS_FILE = CURRENT_DIR / "prompts_agent.yaml"

def load_prompts(file_path: Path) -> dict:
    if not file_path.exists():
        print(f"[INIT FATAL] Prompts file not found at: {file_path}")
        sys.exit(1)
    try:
        with open(file_path, "r", encoding="utf-8-sig") as f:
            data = yaml.safe_load(f)
        return data
    except Exception as e:
        print(f"[INIT FATAL] YAML Parse Error: {e}")
        sys.exit(1)

PROMPTS = load_prompts(PROMPTS_FILE)
llm = StructuredLLMClient()

class FinalStoryOutput(BaseModel):
    story: str = Field(description="The fully synthesized Jira Agile Story")

# ---------------------------------------------------------
# Nodes
# ---------------------------------------------------------

def phase0_extract(state: WorkflowState) -> dict:
    if state.get("who") or state.get("current_phase") != "phase0":
        return {}
    sys_prompt = PROMPTS["extractor"]["system"]
    result = llm.query(sys_prompt, f"Raw input: {state['raw_input']}", ExtractorOutput)
    missing = [k for k in ["who", "what", "why"] if not getattr(result, k)]
    return {
        "who": result.who, "what": result.what, "why": result.why,
        "ac_evidence": result.ac_evidence, "missing_fields": missing,
        "current_phase": "phase1" if missing else "phase2"
    }

def phase1_lock(state: WorkflowState) -> dict:
    missing = state.get("missing_fields", [])
    if not missing:
        return {"current_phase": "phase2"}
    
    target = missing[0]
    friendly_names = {
        "who": "Persona (e.g., User, Admin, Developer)",
        "what": "Feature/Action (What exactly needs to be built?)",
        "why": "Business Value (Why is this feature important?)"
    }
    display_name = friendly_names.get(target, target)

    if not state.get("user_injected_response"):
        retries = state.get("phase1_retries", 0)
        if retries >= 3:
            return {"is_aborted": True, "abort_reason": f"System could not clarify '{display_name}' after 3 attempts.", "action_required": False}
        
        rejection = state.get("last_rejection_reason")
        prompt_msg = f"❌ [Invalid Input]: {rejection}\n👉 Please clarify the {display_name}:" if rejection \
                     else f"🔍 I need more details about the {display_name}.\nCould you please describe it?"
        return {"action_required": True, "action_prompt": prompt_msg}

    user_val = state["user_injected_response"]
    sys_prompt = PROMPTS["validator"]["system"].format(field=target)
    result = llm.query(sys_prompt, f"User provided: {user_val}", ValidatorOutput)
    
    if result.is_valid:
        new_missing = missing[1:]
        return {
            target: result.normalized_value, "missing_fields": new_missing,
            "phase1_retries": 0, "last_rejection_reason": None,
            "user_injected_response": None, "action_required": False,
            "current_phase": "phase1" if new_missing else "phase2"
        }
    return {
        "phase1_retries": state.get("phase1_retries", 0) + 1,
        "last_rejection_reason": result.rejection_reason,
        "user_injected_response": None, "action_required": False
    }

def phase2_tech_lead(state: WorkflowState) -> dict:
    if state.get("pending_questions") or state.get("tech_notes"):
        return {}
    sys_prompt = PROMPTS["tech_lead"]["system"].format(what=state["what"], why=state["why"])
    result = llm.query(sys_prompt, "Review and generate technical questions.", TechQuestionsOutput)
    
    return {
        "pending_questions": result.questions, 
        "total_tech_questions": len(result.questions),
        "current_phase": "phase2_ask"
    }

def phase2_ask_questions(state: WorkflowState) -> dict:
    questions = state.get("pending_questions", [])
    total = state.get("total_tech_questions", 0)
    
    if not questions:
        return {"current_phase": "phase3"}
    
    current_idx = (total - len(questions)) + 1
    current_q = questions[0]
    
    if not state.get("user_injected_response"):
        instruction = "\n(Note: This is optional. Type 'skip' to move to the next question)"
        return {
            "action_required": True, 
            "action_prompt": f"🛠 [Technical Lead Question {current_idx}/{total}]:\n{current_q}{instruction}"
        }

    user_answer = state["user_injected_response"].strip().lower()
    
    # Strict Skip Logic (Hardcoded to bypass LLM and ignore "I don't know")
    if user_answer == "skip":
        return {
            "pending_questions": questions[1:], 
            "user_injected_response": None, 
            "action_required": False,
            "current_phase": "phase2_ask" if len(questions) > 1 else "phase3"
        }

    sys_prompt = PROMPTS["inline_validator"]["system"].format(question=current_q, answer=user_answer)
    result = llm.query(sys_prompt, f"Evaluate answer: {user_answer}", ValidatorOutput)
    
    new_notes = state.get("tech_notes", [])
    if result.is_valid and result.normalized_value:
        new_notes.append(f"Constraint derived from '{current_q}': {result.normalized_value}")
        
    # Moving to next question regardless of validity (unless you want to loop on invalid)
    return {
        "pending_questions": questions[1:], 
        "tech_notes": new_notes, 
        "user_injected_response": None, 
        "action_required": False, 
        "current_phase": "phase2_ask" if len(questions) > 1 else "phase3"
    }

def phase3_synthesize(state: WorkflowState) -> dict:
    if state.get("final_story") and not state.get("feedback_raw"):
        return {}
    tech_notes_str = "\n".join(state.get("tech_notes", []))
    sys_prompt = PROMPTS["agile_coach"]["system"].format(
        who=state["who"], what=state["what"], why=state["why"],
        tech_notes=tech_notes_str, ac_evidence=state.get("ac_evidence", ""),
        feedback=state.get("feedback_raw", "")
    )
    result = llm.query(sys_prompt, "Generate final Jira story.", FinalStoryOutput)
    return {"final_story": result.story, "current_phase": "phase3_feedback", "feedback_raw": None}

def phase3_feedback(state: WorkflowState) -> dict:
    retries = state.get("feedback_retries", 0)
    user_input = (state.get("user_injected_response") or "").strip().lower()
    
    if retries >= 3 or user_input == "confirm":
        return {"is_complete": True, "action_required": False}
    
    if not state.get("user_injected_response"):
        prompt = f"\n[Agile Coach Output]:\n{state['final_story']}\n\nType 'confirm' to accept, or provide feedback:"
        return {"action_required": True, "action_prompt": prompt}
        
    return {"feedback_raw": state["user_injected_response"], "feedback_retries": retries + 1,
            "user_injected_response": None, "action_required": False, "current_phase": "phase3"}

# ---------------------------------------------------------
# Graph Compilation
# ---------------------------------------------------------
def route_start(state: WorkflowState) -> str:
    phase = state.get("current_phase", "phase0")
    routes = {
        "phase0": "phase0_extract", "phase1": "phase1_lock", "phase2": "phase2_tech_lead", 
        "phase2_ask": "phase2_ask_questions", "phase3": "phase3_synthesize", "phase3_feedback": "phase3_feedback"
    }
    return routes.get(phase, "phase0_extract")

builder = StateGraph(WorkflowState)
builder.add_node("phase0_extract", phase0_extract)
builder.add_node("phase1_lock", phase1_lock)
builder.add_node("phase2_tech_lead", phase2_tech_lead)
builder.add_node("phase2_ask_questions", phase2_ask_questions)
builder.add_node("phase3_synthesize", phase3_synthesize)
builder.add_node("phase3_feedback", phase3_feedback)

builder.add_conditional_edges(START, route_start)
builder.add_conditional_edges("phase0_extract", lambda x: "phase1_lock" if x.get("current_phase")=="phase1" else "phase2_tech_lead")
builder.add_conditional_edges("phase1_lock", lambda x: END if x.get("action_required") or x.get("is_aborted") else ("phase1_lock" if x.get("current_phase")=="phase1" else "phase2_tech_lead"))
builder.add_edge("phase2_tech_lead", "phase2_ask_questions")
builder.add_conditional_edges("phase2_ask_questions", lambda x: END if x.get("action_required") else ("phase2_ask_questions" if x.get("current_phase")=="phase2_ask" else "phase3_synthesize"))
builder.add_edge("phase3_synthesize", "phase3_feedback")
builder.add_conditional_edges("phase3_feedback", lambda x: END if x.get("action_required") or x.get("is_complete") else "phase3_synthesize")

graph = builder.compile()
