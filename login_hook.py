"""OIDC login hook: require an invitation in the invitations table.

Login is allowed only if the user's email has a 'pending' or 'accepted'
invitation.  Revoked invitations do not count.

Usage:
    KLANGK_OIDC_LOGIN_HOOK=login_hook.require_invitation
"""

from klangk_backend.model import get_db


async def require_invitation(provider, claims, email, tokens):
    """Reject login unless the email has a pending or accepted invitation."""
    db = await get_db()
    try:
        cursor = await db.execute(
            "SELECT 1 FROM invitations WHERE email = ? AND status IN ('pending', 'accepted')",
            (email,),
        )
        row = await cursor.fetchone()
    finally:
        await db.close()

    if row is None:
        raise PermissionError(f"No invitation found for {email}")
