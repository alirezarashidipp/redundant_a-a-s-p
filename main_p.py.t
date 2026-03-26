from graph import graph

def run_pipeline():
    print("=== Jira Story Generator Pipeline (Stateless K8s Pattern) ===")
    raw_text = input("Enter raw unstructured requirement: ")
    
    if not raw_text.strip():
        print("[FATAL] Input cannot be empty. Aborting.")
        return

    # Payload initial definition
    current_state = {
        "raw_input": raw_text,
        "who": None, "what": None, "why": None, "ac_evidence": None,
        "missing_fields": [], "phase1_retries": 0, "last_rejection_reason": None,
        "is_aborted": False, "abort_reason": None,
        "pending_questions": [], "tech_notes": [],
        "final_story": None, "feedback_retries": 0, "is_complete": False, "feedback_raw": None,
        "action_required": False, "action_prompt": None, "user_injected_response": None,
        "current_phase": "phase0"
    }

    while True:
        try:
            # Full state is passed in, processed, and explicitly yielded out
            current_state = graph.invoke(current_state)
            
            if current_state.get("is_aborted"):
                print(f"\n[ABORTED] {current_state.get('abort_reason')}")
                break
                
            if current_state.get("is_complete"):
                print("\n=== FINAL AGILE STORY ===")
                print(current_state.get("final_story", "No story generated."))
                print("=========================")
                break

            # Process state requirement for HitL
            if current_state.get("action_required"):
                prompt_msg = current_state.get("action_prompt", "Input required:")
                print(f"\n[Action Required] {prompt_msg}")
                
                user_response = input("> ")
                if user_response.strip().lower() == "exit":
                    print("[Process Terminated]")
                    break
                
                # Mutate state before re-invoking
                current_state["user_injected_response"] = user_response
                current_state["action_required"] = False
            else:
                print("[FATAL] Execution suspended without action flag.")
                break

        except Exception as e:
            print(f"[FATAL ERROR] Pipeline crashed: {e}")
            break

if __name__ == "__main__":
    run_pipeline()
