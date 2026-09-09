# 🚚 End-to-End PTL Logistics Pipeline (SQL)

### 📌 Project Overview
This repository contains a robust, enterprise-grade SQL data pipeline designed to analyze and optimize Part-Truck-Load (PTL) logistics operations. At over 800 lines of complex SQL logic, this script extracts raw operational data and transforms it into actionable financial and performance metrics at the individual shipment level.

### 🛠️ Technical Complexity & Features
This pipeline makes extensive use of **25+ Common Table Expressions (CTEs)**, advanced **Window Functions** (`ROW_NUMBER`, `OVER`, `PARTITION BY`), and dynamic multi-table `JOIN` logic to achieve the following:

*   **Cost Allocation Engine:** Dynamically apportions high-level trip costs (Linehaul, Pickup, Delivery runs) down to the individual shipment level based on volumetric weight ratios and docket counts. 
*   **Dynamic SLA & TAT Tracking:** Calculates strict Turnaround Time (TAT) compliances and categorizes deliveries into automated SLA matrices ('On-Time', 'SLA Breach', 'In-Transit') based on logic that adjusts Estimated Delivery Dates (EDDs) for valid exception reasons.
*   **Financial & Ageing Analytics:** Consolidates ERP revenue logic (Basic freight, ODAs, GST) and generates complex Accounts Receivable ageing buckets (0-5 Days, 16-30 Days, etc.) to track outstanding collections.

### 📁 Repository Structure
*   `ptl_pipeline_metrics.sql`: The primary sanitised stored procedure containing all data transformations, allocations, and aggregations.
*   `/prototype`: Contains HTML and image mockups of the final Tableau dashboard driven by this pipeline.

*(Note: Database names, table names, and proprietary schema details have been fully anonymized to protect company confidentiality.)*
