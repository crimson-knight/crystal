# Phase 0: Project Documentation & Visual Map

## Objective
Create an Obsidian canvas and linked phase articles at the repo root that serve as a persistent project management layer. This ensures anyone (or any AI context) picking up the project can immediately understand scope, status, dependencies, and next steps.

## Prerequisites
None -- this is the first phase.

## Implementation Steps

### Step 0.1: Create Master Plan Document
**File:** `INCREMENTAL_PLAN.md` (repo root)

Contains:
- Status dashboard with checklist of all 7 phases
- ASCII architecture diagrams (current pipeline, target pipeline)
- Phase dependency graph
- Expected speedup table
- Key files reference table
- Quick reference (build commands, environment variables)
- Decision log with dates and rationale
- Benchmarks table (filled in as phases complete)

### Step 0.2: Create Phase Detail Articles
**Files:** `IC_PHASE_1_WATCH.md` through `IC_PHASE_7_SEMANTIC.md` (repo root)

Each article contains:
- Objective and scope
- Prerequisites (which prior phases must be complete)
- Numbered, ordered implementation steps
- Files to create and modify (with line references where known)
- Code patterns to follow (with examples from existing codebase)
- Success criteria (checkboxes)
- Testing instructions (shell commands)
- Risks and mitigations table

### Step 0.3: Create Obsidian Canvas
**File:** `INCREMENTAL_PLAN.canvas` (repo root)

JSON format with:
- **Top group**: Current 14-stage compiler pipeline as horizontal flow
- **Middle section**: 7 implementation phases as file nodes linking to detail articles
- **Connecting edges**: From phases to pipeline stages they affect
- **Color coding**: Gray = not started, yellow = in progress, green = complete
- Phase dependency edges showing implementation order

## Files Summary

### New Files
| File | Purpose |
|------|---------|
| `INCREMENTAL_PLAN.md` | Master plan overview and status dashboard |
| `INCREMENTAL_PLAN.canvas` | Obsidian visual map |
| `IC_PHASE_0_DOCS.md` | This document |
| `IC_PHASE_1_WATCH.md` | Phase 1 detailed design |
| `IC_PHASE_2_CACHE.md` | Phase 2 detailed design |
| `IC_PHASE_3_PARALLEL_PARSE.md` | Phase 3 detailed design |
| `IC_PHASE_4_CODEGEN_CACHE.md` | Phase 4 detailed design |
| `IC_PHASE_5_PARALLEL_CHECKS.md` | Phase 5 detailed design |
| `IC_PHASE_6_SIGNATURES.md` | Phase 6 detailed design |
| `IC_PHASE_7_SEMANTIC.md` | Phase 7 detailed design |

## Success Criteria
- [x] `INCREMENTAL_PLAN.md` exists at repo root with all sections populated
- [x] `IC_PHASE_0_DOCS.md` exists (this file)
- [x] All 7 `IC_PHASE_*.md` files exist with complete detail
- [ ] `INCREMENTAL_PLAN.canvas` opens correctly in Obsidian
- [ ] Canvas nodes link to the correct phase article files
- [ ] Opening the canvas gives an immediate visual understanding of scope and dependencies
