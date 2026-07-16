# Aurora Queue

Aurora Queue is a synthetic operational study of a three-step publishing
workflow: capture a request, validate its fields, then publish the accepted
result. It contains aggregate demonstration data only - no people, customers,
clinical records, credentials, or private source material.

The study covers six monthly observations from January through June 2026.
Completed requests rose from 120 in January to 210 in June. Median queue time
fell from 24 minutes to 11 minutes, while on-time completion rose from 84% to
95%. The committed `metrics.csv` file contains every monthly value.

Prepare a compact narrative that explains the purpose, the three-step workflow,
the six-month result, and the evidence limits. Include one focused chart of
median queue time by month from `metrics.csv`; keep metrics with different units
out of that shared axis.

These observations are descriptive rather than causal. The fixture provides no
uncertainty intervals, cost measures, comparator, or evidence that the workflow
caused the changes. Those limits need explicit human-readable disclosure.
