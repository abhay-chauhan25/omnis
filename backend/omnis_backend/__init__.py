"""OMNIS backend service.

Started by the macOS app as a child process. Talks JSON lines over standard
input and output. It produces answers and (later) proposes actions. It never
executes actions; the app does that after its own permission checks.
"""

__version__ = "0.1.0"
