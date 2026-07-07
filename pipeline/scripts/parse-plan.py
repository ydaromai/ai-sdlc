#!/usr/bin/env python3
"""Parse a dev plan markdown file into a dependency graph JSON.

Usage: parse-plan.py <plan.md>

Output: JSON to stdout with structure:
{
  "epic": "Epic Title",
  "stories": [
    {
      "id": "1",
      "title": "Story title",
      "expert": "Frontend",
      "model": "opus",
      "depends_on": [],
      "tasks": [
        {
          "id": "1.1",
          "title": "Task title",
          "files_to_create": ["path/to/file"],
          "files_to_modify": ["path/to/file"]
        }
      ]
    }
  ],
  "groups": [
    {"group": 1, "stories": ["1", "2"]},
    {"group": 2, "stories": ["3"]},
    {"group": 3, "stories": ["4"]}
  ]
}
"""

import os
import re
import json
import sys


def parse_plan(filepath):
    with open(filepath, 'r', errors='replace') as f:
        text = f.read()

    result = {
        'epic': '',
        'stories': [],
        'skipped': [],
        'groups': [],
    }

    # Extract epic title
    epic_m = re.search(r'^## EPIC:\s*(.+)$', text, re.MULTILINE)
    if epic_m:
        result['epic'] = epic_m.group(1).strip()

    # Split into story sections.
    # Canonical heading form (mandated by pipeline/templates/task-breakdown-definition-template.md
    # "Heading format" and enforced by the dev-plan-expert Hard Gate #6) is:
    #     ## STORY N: <title>
    # The em-dash '—' alternative below is BACKWARD-COMPAT for plans generated before the
    # spec was tightened. New plans MUST use the colon form; future maintenance may tighten
    # this regex to ':' only once legacy plans are converted.
    story_splits = re.split(r'^## STORY (\d+)\s*[:—]', text, flags=re.MULTILINE)
    # story_splits: [preamble, id1, body1, id2, body2, ...]

    for i in range(1, len(story_splits) - 1, 2):
        story_id = story_splits[i].strip()
        story_body = story_splits[i + 1]

        story = {
            'id': story_id,
            'title': '',
            'expert': '',
            'model': os.environ.get('PIPELINE_BUILD_MODEL', 'opus').strip() or 'opus',
            'depends_on': [],
            'status': 'pending',
            'tasks': [],
        }

        # Detect story status from explicit markers.
        # IMPORTANT: scan ONLY the story-header section (everything BEFORE the first
        # `### TASK ...`). Otherwise a `**Status:** ✅ DONE` inside a single task body
        # would mark the entire story as done. The story-level marker must live in the
        # header alongside `**PRD:**`, `**Estimated Effort:**`, etc.
        story_header = re.split(r'(?m)^### TASK \d', story_body, maxsplit=1)[0]
        if re.search(r'\*\*Status:\*\*\s*✅\s*DONE', story_header):
            story['status'] = 'done'
        elif re.search(r'\*\*Status:\*\*\s*🔄', story_header):
            story['status'] = 'in_progress'
        elif re.search(r'\*\*Status:\*\*\s*❌', story_header):
            story['status'] = 'blocked'

        # Extract story title (first line of body)
        title_m = re.search(r'\*\*Story Title:\*\*\s*(.+)', story_body)
        if title_m:
            story['title'] = title_m.group(1).strip()
        else:
            # Fallback: use first non-empty line
            first_line = story_body.strip().split('\n')[0].strip()
            story['title'] = first_line

        # Extract tasks. Canonical heading: `### TASK N.M: <title>`. Em-dash is backward-compat.
        task_splits = re.split(r'^### TASK (\d+\.\d+)\s*[:—]', story_body, flags=re.MULTILINE)
        for j in range(1, len(task_splits) - 1, 2):
            task_id = task_splits[j].strip()
            task_body = task_splits[j + 1]

            task = {
                'id': task_id,
                'title': '',
                'status': 'pending',
                'files_to_create': [],
                'files_to_modify': [],
            }

            # Detect task status
            if re.search(r'\*\*Status:\*\*\s*✅\s*DONE', task_body):
                task['status'] = 'done'

            # Task title
            tt_m = re.search(r'\*\*Task Title:\*\*\s*(.+)', task_body)
            if tt_m:
                task['title'] = tt_m.group(1).strip()

            # Files to create (W2: strip backticks from markdown paths)
            # Negative lookahead `(?!/Modify)` so this doesn't also swallow the combined header.
            ftc_section = re.search(
                r'\*\*Files to Create(?!/Modify)\*?\*?:?\*\*\s*\n((?:- .+\n?)+)', task_body
            )
            if ftc_section:
                task['files_to_create'] = [
                    re.sub(r'^-\s+', '', line.strip()).split(' ')[0].strip('`')
                    for line in ftc_section.group(1).strip().split('\n')
                    if line.strip().startswith('-')
                ]

            # Files to modify (W2: strip backticks from markdown paths)
            ftm_section = re.search(
                r'\*\*Files to Modify:?\*\*\s*\n((?:- .+\n?)+)', task_body
            )
            if ftm_section:
                task['files_to_modify'] = [
                    re.sub(r'^-\s+', '', line.strip()).split(' ')[0].strip('`')
                    for line in ftm_section.group(1).strip().split('\n')
                    if line.strip().startswith('-')
                ]

            # Combined "Files to Create/Modify" section (dev-plan-expert spec format).
            # If a bullet says "(create)" → goes to files_to_create; "(modify)" → files_to_modify.
            # Unmarked bullets default to files_to_create (consumers union the two lists anyway).
            ftcm_section = re.search(
                r'\*\*Files to Create/Modify:?\*\*\s*\n((?:- .+\n?)+)', task_body
            )
            if ftcm_section:
                for line in ftcm_section.group(1).strip().split('\n'):
                    if not line.strip().startswith('-'):
                        continue
                    raw = re.sub(r'^-\s+', '', line.strip())
                    path = raw.split(' ')[0].strip('`')
                    if '(modify)' in raw.lower():
                        if path not in task['files_to_modify']:
                            task['files_to_modify'].append(path)
                    else:
                        if path not in task['files_to_create']:
                            task['files_to_create'].append(path)

            story['tasks'].append(task)

        result['stories'].append(story)

    # Parse execution table for expert, model, dependencies
    # Look for table with: | Story | Expert | Model | Depends On | Isolation |
    table_m = re.findall(
        r'\|\s*(\d+)\s*\|\s*(.+?)\s*\|\s*(\w+)\s*\|\s*(.+?)\s*\|\s*\w+\s*\|',
        text
    )
    for row in table_m:
        story_num, expert, model, depends = row
        story_num = story_num.strip()
        for story in result['stories']:
            if story['id'] == story_num:
                story['expert'] = expert.strip()
                # Pipeline-wide mandate (2026-06-11): all builds run on opus,
                # regardless of what the plan's execution table says. The Model
                # column is still parsed (regex captures it) but no longer
                # honored — existing plans with opus/sonnet rows run opus too.
                # Override (2026-06-13): PIPELINE_BUILD_MODEL forces a different
                # build model when opus is unavailable for the active account
                # (e.g. after a re-login that drops opus access). Unset → opus.
                story['model'] = os.environ.get('PIPELINE_BUILD_MODEL', 'opus').strip() or 'opus'
                dep_str = depends.strip()
                if dep_str and dep_str.lower() != 'none':
                    # Parse "Story 2", "Story 1 + Story 3", etc.
                    deps = re.findall(r'Story\s+(\d+)', dep_str)
                    story['depends_on'] = deps

    # Fallback: derive story-level deps from task-level `**Depends On:** TASK M.y` lines.
    # A story N depends on story M when any task inside N references a task that LIVES IN
    # story M (M != N). We build a task-id → owning-story-id map first, because tasks can
    # be moved between stories without renumbering (e.g. when stories are merged).
    # Only kicks in for stories that have no deps from the execution table.
    story_splits_for_deps = re.split(r'^## STORY (\d+)\s*[:—]', text, flags=re.MULTILINE)

    # Build task ownership map: task-id (e.g. "3.1") → owning story id (e.g. "2" if Story 3
    # was merged into Story 2). Use the FULL task id including any sub-levels like "3.1.5".
    task_owner = {}
    for i in range(1, len(story_splits_for_deps) - 1, 2):
        sid = story_splits_for_deps[i].strip()
        body = story_splits_for_deps[i + 1]
        for tm in re.finditer(r'^###+ TASK (\d+(?:\.\d+)+)', body, re.MULTILINE):
            task_owner[tm.group(1)] = sid

    for i in range(1, len(story_splits_for_deps) - 1, 2):
        sid = story_splits_for_deps[i].strip()
        body = story_splits_for_deps[i + 1]
        story_obj = next((s for s in result['stories'] if s['id'] == sid), None)
        if story_obj is None or story_obj['depends_on']:
            continue  # explicit deps take precedence
        derived = set()
        for m in re.finditer(r'\*\*Depends On:\*\*\s*([^\n]+)', body):
            # Match full task IDs including sub-levels (e.g. "3.1.5" not just "3.1").
            for ref in re.findall(r'TASK\s+(\d+(?:\.\d+)+)', m.group(1)):
                # Look up the actual owning story for this task. Fall back to the leading
                # digit if the task ID isn't in the map (defensive — shouldn't happen).
                owner = task_owner.get(ref, ref.split('.', 1)[0])
                if owner != sid:
                    derived.add(owner)
        story_obj['depends_on'] = sorted(derived, key=lambda x: int(x))

    # Separate done stories from pending ones
    done_ids = {s['id'] for s in result['stories'] if s['status'] == 'done'}
    result['skipped'] = sorted(done_ids, key=lambda x: int(x))

    # Build dependency groups (topological sort into parallel batches)
    # Done stories count as already completed for dependency resolution
    remaining = {s['id'] for s in result['stories'] if s['status'] != 'done'}
    completed = set(done_ids)  # done stories satisfy dependencies
    group_num = 0

    while remaining:
        group_num += 1
        # Find stories whose deps are all completed
        ready = []
        for s in result['stories']:
            if s['id'] in remaining:
                if all(d in completed for d in s['depends_on']):
                    ready.append(s['id'])

        if not ready:
            # Deadlock — add all remaining to break cycle
            ready = list(remaining)

        result['groups'].append({
            'group': group_num,
            'stories': sorted(ready, key=lambda x: int(x)),
        })

        for sid in ready:
            remaining.discard(sid)
            completed.add(sid)

    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: parse-plan.py <plan.md>', file=sys.stderr)
        sys.exit(2)

    plan = parse_plan(sys.argv[1])
    print(json.dumps(plan, indent=2, ensure_ascii=False))
