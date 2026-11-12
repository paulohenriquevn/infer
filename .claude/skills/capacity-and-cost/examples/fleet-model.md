# Fleet model as a table

Generated from `fleet-model.csv`, which `fleet_model.py` writes. Use this to read the model as a spreadsheet: inputs on the left, outputs on the right, one row per combination. Everything is Inferred and provisional (capacity from single runs, b Unknown); method and caveats in `../references/fleet-recalculation.md`. This view shows the base scenario for d, h, s and the DCP1 and DCP4 capacities; the CSV also has low and high d, h, s, b = 2.5 and the 16-session capacity.

Columns: U users; d, h, s demand factors; phi at Claude latency; b our request time over Claude's; phi' corrected loop share; f streams per looping session; L looping sessions; S streams; N sessions per replica; raw S / N; margin 1 + 3 / sqrt(L); R replicas; RPM replicas per machine; load, spare and total machines; US$/h per machine; US$ k per month; US$ per user per month.

| U | d | h | s | phi | b | phi' | f | L | S | N | raw | margin | R | Machine | RPM | Load | Spare | Total | US$/h | US$ k/month | US$/user |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 24 | 31.89 | 1.1163 | 36 | AWS g7e.24xlarge on-demand us-east-1 | 1 | 36 | 8 | 44 | 16.57216 | 532.3 | 53.23 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 24 | 31.89 | 1.1163 | 36 | AWS g7e.48xlarge on-demand us-east-1 | 2 | 18 | 4 | 22 | 33.14432 | 532.3 | 53.23 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 24 | 31.89 | 1.1163 | 36 | AWS g7e.24xlarge EC2 Instance SP 1yr no upfront | 1 | 36 | 8 | 44 | 10.44046 | 335.3 | 33.53 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 24 | 31.89 | 1.1163 | 36 | AWS g7e.24xlarge EC2 Instance SP 3yr no upfront | 1 | 36 | 8 | 44 | 7.15917 | 230.0 | 23.0 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 24 | 31.89 | 1.1163 | 36 | Nebius 8x RTX PRO 6000 list | 2 | 18 | 4 | 22 | 14.4 | 231.3 | 23.13 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 8 | 95.68 | 1.1163 | 107 | AWS g7e.24xlarge on-demand us-east-1 | 1 | 107 | 22 | 129 | 16.57216 | 1,560.6 | 156.06 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 8 | 95.68 | 1.1163 | 107 | AWS g7e.48xlarge on-demand us-east-1 | 2 | 54 | 11 | 65 | 33.14432 | 1,572.7 | 157.27 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 8 | 95.68 | 1.1163 | 107 | AWS g7e.24xlarge EC2 Instance SP 1yr no upfront | 1 | 107 | 22 | 129 | 10.44046 | 983.2 | 98.32 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 8 | 95.68 | 1.1163 | 107 | AWS g7e.24xlarge EC2 Instance SP 3yr no upfront | 1 | 107 | 22 | 129 | 7.15917 | 674.2 | 67.42 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 1.0 | 0.256 | 1.15 | 665.6 | 765.4 | 8 | 95.68 | 1.1163 | 107 | Nebius 8x RTX PRO 6000 list | 2 | 54 | 11 | 65 | 14.4 | 683.3 | 68.33 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 24 | 50.79 | 1.0921 | 56 | AWS g7e.24xlarge on-demand us-east-1 | 1 | 56 | 12 | 68 | 16.57216 | 822.6 | 82.26 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 24 | 50.79 | 1.0921 | 56 | AWS g7e.48xlarge on-demand us-east-1 | 2 | 28 | 6 | 34 | 33.14432 | 822.6 | 82.26 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 24 | 50.79 | 1.0921 | 56 | AWS g7e.24xlarge EC2 Instance SP 1yr no upfront | 1 | 56 | 12 | 68 | 10.44046 | 518.3 | 51.83 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 24 | 50.79 | 1.0921 | 56 | AWS g7e.24xlarge EC2 Instance SP 3yr no upfront | 1 | 56 | 12 | 68 | 7.15917 | 355.4 | 35.54 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 24 | 50.79 | 1.0921 | 56 | Nebius 8x RTX PRO 6000 list | 2 | 28 | 6 | 34 | 14.4 | 357.4 | 35.74 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 8 | 152.36 | 1.0921 | 167 | AWS g7e.24xlarge on-demand us-east-1 | 1 | 167 | 34 | 201 | 16.57216 | 2,431.6 | 243.16 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 8 | 152.36 | 1.0921 | 167 | AWS g7e.48xlarge on-demand us-east-1 | 2 | 84 | 17 | 101 | 33.14432 | 2,443.7 | 244.37 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 8 | 152.36 | 1.0921 | 167 | AWS g7e.24xlarge EC2 Instance SP 1yr no upfront | 1 | 167 | 34 | 201 | 10.44046 | 1,531.9 | 153.19 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 8 | 152.36 | 1.0921 | 167 | AWS g7e.24xlarge EC2 Instance SP 3yr no upfront | 1 | 167 | 34 | 201 | 7.15917 | 1,050.5 | 105.05 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 2.0 | 0.4076 | 1.15 | 1059.9 | 1218.9 | 8 | 152.36 | 1.0921 | 167 | Nebius 8x RTX PRO 6000 list | 2 | 84 | 17 | 101 | 14.4 | 1,061.7 | 106.17 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 24 | 63.28 | 1.0826 | 69 | AWS g7e.24xlarge on-demand us-east-1 | 1 | 69 | 14 | 83 | 16.57216 | 1,004.1 | 100.41 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 24 | 63.28 | 1.0826 | 69 | AWS g7e.48xlarge on-demand us-east-1 | 2 | 35 | 7 | 42 | 33.14432 | 1,016.2 | 101.62 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 24 | 63.28 | 1.0826 | 69 | AWS g7e.24xlarge EC2 Instance SP 1yr no upfront | 1 | 69 | 14 | 83 | 10.44046 | 632.6 | 63.26 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 24 | 63.28 | 1.0826 | 69 | AWS g7e.24xlarge EC2 Instance SP 3yr no upfront | 1 | 69 | 14 | 83 | 7.15917 | 433.8 | 43.38 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 24 | 63.28 | 1.0826 | 69 | Nebius 8x RTX PRO 6000 list | 2 | 35 | 7 | 42 | 14.4 | 441.5 | 44.15 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 8 | 189.84 | 1.0826 | 206 | AWS g7e.24xlarge on-demand us-east-1 | 1 | 206 | 42 | 248 | 16.57216 | 3,000.2 | 300.02 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 8 | 189.84 | 1.0826 | 206 | AWS g7e.48xlarge on-demand us-east-1 | 2 | 103 | 21 | 124 | 33.14432 | 3,000.2 | 300.02 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 8 | 189.84 | 1.0826 | 206 | AWS g7e.24xlarge EC2 Instance SP 1yr no upfront | 1 | 206 | 42 | 248 | 10.44046 | 1,890.1 | 189.01 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 8 | 189.84 | 1.0826 | 206 | AWS g7e.24xlarge EC2 Instance SP 3yr no upfront | 1 | 206 | 42 | 248 | 7.15917 | 1,296.1 | 129.61 |
| 10,000 | 0.4 | 0.5 | 1.3 | 0.256 | 3.0 | 0.5079 | 1.15 | 1320.6 | 1518.7 | 8 | 189.84 | 1.0826 | 206 | Nebius 8x RTX PRO 6000 list | 2 | 103 | 21 | 124 | 14.4 | 1,303.5 | 130.35 |

Price sources: AWS on-demand from the public price data published 2026-11-10; AWS Savings Plans from the price list version 20261110215713; Nebius from https://nebius.com/prices; all read 2026-11-12. To change an input, edit `fleet_model.py`, run `python3 fleet_model.py --check`, then `python3 fleet_model.py > fleet-model.csv` and regenerate this table.
