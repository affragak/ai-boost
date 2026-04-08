# Open WebUI 0.8 — Model Access Control Deep Dive

> **Context**: Debugging why a newly-created `user`-role account could not see any
> models in Open WebUI 0.8.12, despite Ollama serving them correctly and the admin
> account seeing them all.

---

## The Problem

After creating user **Evaki** via the `/api/v1/auths/add` endpoint (role: `user`),
she could log in but the model selector was empty. The admin saw all 10 models.
The Ollama service was healthy.

```
GET /api/v1/models   (as Evaki)
→ {"data": []}       ← empty, expected 10 models
```

---

## Investigation

### Wrong assumptions we had

| Assumption | Reality |
|---|---|
| `access_control: null` means "public to everyone" | It means "no restriction object set", but still requires explicit DB grants |
| `access_grants: []` clears restrictions (opens access) | It clears **all** grants, making the model invisible to non-admins |
| The `/api/v1/models` route simply lists Ollama models | It queries a DB and filters by grant table |

### How Open WebUI 0.8 actually filters models

The `get_filtered_models()` function in `open_webui/utils/models.py` applies this
logic for any `user`-role account:

```python
if model_info:                          # model has a DB entry
    if (
        user.id == model_info['user_id']    # user owns the model
        or model['id'] in accessible_model_ids  # user has an explicit grant
    ):
        filtered_models.append(model)
elif user.role == 'admin':              # NO DB entry → admin-only
    filtered_models.append(model)
```

Key points:

1. **Raw Ollama models with no DB entry** → visible to admins only.
2. **Models with a DB entry** → visible only if the user has an explicit grant
   in the `AccessGrant` table.
3. **`access_control: null`** does NOT automatically open access; it simply means
   no restriction object is stored, and the code falls through to the grant check.

### The `AccessGrant` table

`AccessGrants.get_accessible_resource_ids()` performs a single batch query:

```sql
SELECT resource_id FROM access_grant
WHERE resource_type = 'model'
  AND resource_id IN (<model_ids>)
  AND permission = 'read'
  AND (
       (principal_type = 'user' AND principal_id = '*')      -- wildcard: all users
    OR (principal_type = 'user' AND principal_id = <uid>)    -- specific user
    OR (principal_type = 'group' AND principal_id IN (<gids>)) -- group members
  )
```

The **wildcard grant** (`principal_id = '*'`) is the mechanism that makes a model
visible to every authenticated user.

---

## What Our Script Was Doing Wrong

The first working version of `create-user` called:

```json
POST /api/v1/models/model/access/update
{ "id": "qwen2.5:7b", "access_control": null, "access_grants": [] }
```

`set_access_grants()` deletes all existing grants for the model and inserts the new
list. Passing `[]` caused it to:

1. Create a DB entry for the model (so the `elif user.role == 'admin'` fallback no
   longer fires for regular users).
2. Delete any pre-existing grants.
3. Insert nothing.

Net result: the model had a DB entry but zero grants → **invisible to all
non-admins**, including the user we just "granted" access to.

---

## The Fix

Grant a wildcard read entry for every model:

```json
POST /api/v1/models/model/access/update
{
  "id": "qwen2.5:7b",
  "access_grants": [
    { "principal_type": "user", "principal_id": "*", "permission": "read" }
  ]
}
```

`normalize_access_grants()` in `open_webui/models/access_grants.py` validates that:
- `principal_type` ∈ `{'user', 'group'}`
- `principal_id` is a non-empty string (`'*'` is valid)
- `permission` ∈ `{'read', 'write'}`

After applying the fix, `GET /api/v1/models` as Evaki returned all 10 models. ✅

---

## Model Visibility Rules — Summary

| Scenario | Admin sees | User sees |
|---|---|---|
| Model has no DB entry | ✅ | ❌ |
| DB entry, `access_grants: []` | ✅ | ❌ |
| DB entry, specific user grant | ✅ | ✅ (that user only) |
| DB entry, group grant | ✅ | ✅ (group members) |
| DB entry, wildcard `principal_id: '*'` | ✅ | ✅ (all users) |

---

## `create-user` Script Behaviour (Post-Fix)

The script now:

1. **Authenticates** as admin via `/api/v1/auths/signin`.
2. **Creates** the new user via `/api/v1/auths/add` with `role: user`.
3. **Fetches** all current models from `/api/v1/models` (admin view).
4. **Sets a wildcard read grant** on every model, creating the DB entry if it
   doesn't exist yet.

Step 4 is **idempotent** — calling it again on an already-configured model simply
replaces the grant list with the same wildcard entry.

### Side effect on new Ollama models

When a new model is pulled with `pull-models`, it has no DB entry and is therefore
**invisible to regular users**. Running `create-user` again (or a future
`fix-model-access` helper) re-grants access.

A permanent solution would be to set `BYPASS_MODEL_ACCESS_CONTROL=true` in the
Open WebUI environment, which skips the entire filter and exposes all models to all
authenticated users — appropriate for a private/family server where everyone should
see everything.

---

## Relevant Source Files

| File | Role |
|---|---|
| `open_webui/utils/models.py` | `get_filtered_models()` — per-user model filtering |
| `open_webui/models/access_grants.py` | `AccessGrants`, `normalize_access_grants()`, `get_accessible_resource_ids()` |
| `open_webui/routers/models.py` | `POST /model/access/update` endpoint |
| `scripts/create-user` | Our provisioning script (fixed in commit `1348815`) |
