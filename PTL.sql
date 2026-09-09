USE [Logistics_Analytics_DB]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* =========================================================================================
   Author:        [Your Name]
   Create date:   [Current Year]
   Description:   End-to-end PTL (Part-Truck-Load) Analytics Pipeline. 
                  Calculates shipment-level revenue, allocates trip costs (Pickup, Linehaul, 
                  Delivery), tracks SLA/TAT compliance, and generates billing/ageing metrics.
   ========================================================================================= */

CREATE PROCEDURE [rpt].[sp_ptl_pipeline_metrics]
    @StartDate DATETIME = NULL,
    @EndDate DATETIME = NULL,
    @CustomerID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;  
    SET LOCK_TIMEOUT 30000;  
  
    WITH  
    -- 1. Deduplicate Branch Pincodes using Window Functions
    Branch_Pincode_Ranked AS (  
        SELECT  
            bm.ID AS BranchID,  
            bm.BranchName,  
            LTRIM(RTRIM(CAST(bm.Pincode AS VARCHAR(20)))) AS BranchPincode,  
            ROW_NUMBER() OVER (  
                PARTITION BY LTRIM(RTRIM(CAST(bm.Pincode AS VARCHAR(20))))  
                ORDER BY bm.ID  
            ) AS rn  
        FROM dim_branch bm WITH (NOLOCK)  
        WHERE bm.Pincode IS NOT NULL  
          AND LTRIM(RTRIM(CAST(bm.Pincode AS VARCHAR(20)))) <> ''  
          AND LTRIM(RTRIM(CAST(bm.Pincode AS VARCHAR(20)))) <> '0'  
    ),  
  
    Branch_Pincode_Map AS (  
        SELECT BranchID, BranchName, BranchPincode  
        FROM Branch_Pincode_Ranked  
        WHERE rn = 1  
    ),  
  
    -- 2. Aggregate Volumetric & Actual Weights
    CFT_Agg AS (  
        SELECT  
            ShipmentId,  
            ShipmentNo,  
            SUM(ISNULL(Pkgs, 0)) AS CFTPackages,  
            SUM(ISNULL(TotalCFTweight, 0)) AS TotalCFTWeight,  
            SUM(ISNULL(TotalACTweight, 0)) AS TotalACTWeightFromCFT,  
            SUM(ISNULL(SelectedWeight, 0)) AS SelectedCFTWeight  
        FROM fct_volumetric_data  
        GROUP BY ShipmentId, ShipmentNo  
    ),  
  
    -- 3. Consolidate Invoice Values
    Invoice_Agg AS (  
        SELECT  
            ShipmentNo,  
            SUM(ISNULL(TRY_CONVERT(DECIMAL(18, 2), InvoiceValue), 0)) AS TotalInvoiceValue  
        FROM fct_invoices WITH (NOLOCK)  
        GROUP BY ShipmentNo  
    ),  
  
    -- 4. Map Geography and Zones
    Pincode_Final AS (  
        SELECT  
            LTRIM(RTRIM(CAST(Pincode AS VARCHAR(20)))) AS Pincode,  
            MAX(ZoneName) AS ZoneName,  
            MAX(Zoneid) AS ZoneId,  
            MAX(State) AS State,  
            MAX(CityName) AS CityName,  
            MAX(PickupBranchId) AS PickupBranchId,  
            MAX(DeliveryBranchId) AS DeliveryBranchId,  
            MAX(SurfaceOdaId) AS SurfaceOdaId  
        FROM dim_pincode WITH (NOLOCK)  
        GROUP BY LTRIM(RTRIM(CAST(Pincode AS VARCHAR(20))))  
    ),  
  
    Customer_Final AS (  
        SELECT  
            CustomerID,  
            MAX(CustomerName) AS CustomerName,  
            MAX(ISNULL(TRY_CONVERT(INT, CreditDays), 0)) AS CreditDays  
        FROM dim_customer WITH (NOLOCK)  
        GROUP BY CustomerID  
    ),  
  
    -- 5. Extract Latest Delivery Attempt Status
    Delivery_Run_Ranked AS (  
        SELECT  
            ShipmentNo,  
            DeliveryStatus,  
            UndlyReasonId,  
            DeliveryDate AS AttemptDate,  
            DeliveryTime AS AttemptTime,  
            Delivered,  
            ROW_NUMBER() OVER (  
                PARTITION BY ShipmentNo  
                ORDER BY DeliveryDate DESC, DeliveryTime DESC, DetailId DESC  
            ) AS rn  
        FROM fct_delivery_run_sheet  
    ),  
  
    Delivery_Run_Latest AS (  
        SELECT ShipmentNo, DeliveryStatus, UndlyReasonId, AttemptDate, AttemptTime, Delivered  
        FROM Delivery_Run_Ranked  
        WHERE rn = 1  
    ),  
  
    -- 6. Core Base Shipment Data Aggregation
    Base_Shipment AS (  
        SELECT  
            d.ID AS ShipmentID,  
            d.ShipmentNo,  
            d.ShipmentDate,  
            d.ServiceTypeId,  
            d.ModeId,  
            d.ContractTypeId AS BookingModeId,  
            d.BillToId AS CustomerID,  
            cm.CustomerName,  
            cm.CreditDays,  
  
            d.BkPincode AS OriginPincode,  
            op.CityName AS OriginCity,  
            op.ZoneName AS OriginZone,  
            COALESCE(obpm.BranchID, op.PickupBranchId) AS OriginBranchId,  
            CASE  
                WHEN obpm.BranchID IS NOT NULL THEN 'BranchMaster Pincode'  
                WHEN op.PickupBranchId IS NOT NULL THEN 'Pincode PickupBranchId Fallback'  
                ELSE 'Origin Branch Not Mapped'  
            END AS OriginBranchMappingSource,              
            op.SurfaceOdaId AS OrgODAType,  
  
            d.DlPincode AS DestPincode,  
            dp.CityName AS DestCity,  
            dp.ZoneName AS DestZone,  
            COALESCE(dbpm.BranchID, dp.DeliveryBranchId) AS DestBranchId,  
            dp.SurfaceOdaId AS DestODAType,  
  
            d.Pieces,  
            d.Packages,  
            d.ActualWeight AS ActualWeightKG,  
            d.ChargedWeightRoundOff AS ChargedWeightKG,  
            ROUND(ISNULL(d.ChargedWeightRoundOff, 0) / 1000.0, 3) AS ChargedWeightMT,  
            d.Volumetricweight AS VolumetricWeightKG,  
  
            COALESCE(NULLIF(di.TotalInvoiceValue, 0), d.DeclaredValue) AS InvoiceValue,  
  
            -- Dynamic Revenue Extrapolation
            ISNULL(d.Rate, 0) AS ShipmentRate,
            ISNULL(d.BasicFreight, 0) AS ShipmentBasicFreight,
            ISNULL(d.PickupODA, 0) AS ShipmentPickupODA,
            ISNULL(d.DestinationODA, 0) AS ShipmentDestinationODA,
            ISNULL(d.SubTotal, 0) AS ShipmentSubTotal,
            ISNULL(d.ShipmentTotal, 0) AS ShipmentTotal,
            ISNULL(d.CGST, 0) AS ShipmentCGST,
            ISNULL(d.SGST, 0) AS ShipmentSGST,
            ISNULL(d.IGST, 0) AS ShipmentIGST,  
  
            d.EstDldate AS EDD,  
            d.DeliveryDate,  
            d.CurrentStatus,  
            d.Billed,  
            d.VehicleNumberID  
  
        FROM fct_shipment d  
        LEFT JOIN Customer_Final cm ON d.BillToId = cm.CustomerID  
        LEFT JOIN Invoice_Agg di ON d.ShipmentNo = di.ShipmentNo  
        LEFT JOIN Pincode_Final op ON LTRIM(RTRIM(CAST(d.BkPincode AS VARCHAR(20)))) = op.Pincode  
        LEFT JOIN Pincode_Final dp ON LTRIM(RTRIM(CAST(d.DlPincode AS VARCHAR(20)))) = dp.Pincode  
        LEFT JOIN Branch_Pincode_Map obpm ON LTRIM(RTRIM(CAST(d.BkPincode AS VARCHAR(20)))) = obpm.BranchPincode  
        LEFT JOIN Branch_Pincode_Map dbpm ON LTRIM(RTRIM(CAST(d.DlPincode AS VARCHAR(20)))) = dbpm.BranchPincode  
        WHERE d.ServiceTypeId IN (1, 3) AND ISNULL(d.CancelShipment, 0) = 0  
    ),  
  
    -- 7. Revenue & SLA Final Calculations
    Revenue_Calc AS (  
        SELECT  
            bd.ShipmentNo,  
            bd.ShipmentRate AS RatePerKg,
            bd.ChargedWeightKG,
            bd.ChargedWeightMT,
  
            CASE
                WHEN dl.UndlyReasonId IN (13, 14, 23) THEN 1 ELSE 0
            END AS ExtraTATDays,
            
            DATEADD(DAY, CASE WHEN dl.UndlyReasonId IN (13, 14, 23) THEN 1 ELSE 0 END, bd.EDD) AS FinalEDD,
            
            bd.ShipmentBasicFreight AS BasicFreight,
            bd.ShipmentPickupODA AS OriginODACharge,
            bd.ShipmentDestinationODA AS DestODACharge,
            bd.ShipmentSubTotal AS ERP_RevenueExcGST,
            bd.ShipmentTotal AS ERP_RevenueIncGST,

            (ISNULL(bd.ShipmentCGST, 0) + ISNULL(bd.ShipmentSGST, 0) + ISNULL(bd.ShipmentIGST, 0)) AS ERP_GST  
        FROM Base_Shipment bd  
        LEFT JOIN Delivery_Run_Latest dl ON bd.ShipmentNo = dl.ShipmentNo  
    ),  
  
    Revenue_Final AS (  
        SELECT  
            rc.*,  
            ROUND(ISNULL(rc.OriginODACharge, 0) + ISNULL(rc.DestODACharge, 0), 2) AS TotalODACharge,
            ROUND(ISNULL(rc.ERP_RevenueExcGST, 0), 2) AS RevenueExclGST,
            ROUND(ISNULL(rc.ERP_RevenueIncGST, 0), 2) AS RevenueInclGST,
            ROUND(ISNULL(rc.ERP_RevenueIncGST, 0) - ISNULL(rc.ERP_RevenueExcGST, 0), 2) AS GSTAmount
        FROM Revenue_Calc rc  
    ),  
  
    -- 8. Advanced Cost Allocation: Linehaul / THC Allocation Logic
    Linehaul_ShipmentWeight AS (  
        SELECT  
            md.Fyear, md.TripId, md.ShipmentNo,  
            SUM(CASE WHEN ISNULL(md.TotalWeight, 0) > 0 THEN ISNULL(md.TotalWeight, 0) ELSE ISNULL(md.Wtloaded, 0) END) AS ShipmentLinehaulWeightKG  
        FROM fct_linehaul_manifest md  
        WHERE md.TripId IS NOT NULL  
        GROUP BY md.Fyear, md.TripId, md.ShipmentNo  
    ),  
  
    Linehaul_TripStats AS (  
        SELECT  
            Fyear, TripId,  
            SUM(ISNULL(ShipmentLinehaulWeightKG, 0)) AS TripTotalWeightKG,  
            COUNT(DISTINCT ShipmentNo) AS TripShipmentCount  
        FROM Linehaul_ShipmentWeight  
        GROUP BY Fyear, TripId  
    ),  
  
    Linehaul_Cost_Allocation AS (  
        SELECT  
            dw.ShipmentNo,  
            ROUND(  
                SUM(  
                    CASE  
                        WHEN ISNULL(ts.TripTotalWeightKG, 0) > 0 THEN ISNULL(tc.HireAmount, 0) * ISNULL(dw.ShipmentLinehaulWeightKG, 0) / NULLIF(ts.TripTotalWeightKG, 0)  
                        WHEN ISNULL(ts.TripShipmentCount, 0) > 0 THEN ISNULL(tc.HireAmount, 0) / NULLIF(ts.TripShipmentCount, 0)  
                        ELSE 0  
                    END  
                ), 2) AS AllocatedLinehaulCost,  
            SUM(ISNULL(dw.ShipmentLinehaulWeightKG, 0)) AS TotalLinehaulWeightKG  
        FROM Linehaul_ShipmentWeight dw  
        LEFT JOIN Linehaul_TripStats ts ON dw.Fyear = ts.Fyear AND dw.TripId = ts.TripId  
        LEFT JOIN fct_linehaul_trips tc ON dw.Fyear = tc.Fyear AND dw.TripId = tc.TripID  
        GROUP BY dw.ShipmentNo  
    ),

    -- 9. Billing and Ageing Logic
    Billing_Support AS (  
        SELECT  
            bd.ShipmentNo,  
            MAX(b.BillID) AS BillID,  
            MAX(b.BillNumber) AS BillNumber,  
            MAX(b.BillDate) AS BillDate,  
            MAX(TRY_CONVERT(DECIMAL(18,2), b.GrandTotal)) AS BillGrandTotal,  
            MAX(TRY_CONVERT(DECIMAL(18,2), b.TotalCollected)) AS BillTotalCollected,  
            MAX(TRY_CONVERT(DECIMAL(18,2), b.BalanceCollectable)) AS BillBalanceCollectable,  
            MAX(b.ClosingDate) AS BillClosingDate  
        FROM Base_Shipment bd  
        INNER JOIN fct_billing_details bd_det WITH (NOLOCK) ON bd.ShipmentNo = bd_det.ShipmentNo  
        INNER JOIN fct_billing b WITH (NOLOCK) ON bd_det.BillID = b.BillID AND bd_det.Fyear = b.Fyear  
        GROUP BY bd.ShipmentNo  
    )  
  
    -- FINAL SELECT: Combining all dimensions, metrics, costs, and SLA buckets
    SELECT  
        bd.ShipmentNo,  
        bd.ShipmentDate,  
        bd.CustomerName,  
        bd.OriginCity,  
        ob.BranchName AS OriginBranch,  
        bd.DestCity,  
        db.BranchName AS DestBranch,  
        CONCAT(ISNULL(bd.OriginZone, 'NA'), ' to ', ISNULL(bd.DestZone, 'NA')) AS LaneName,  
  
        bd.Pieces,  
        bd.ActualWeightKG,  
        bd.ChargedWeightKG,  
        vm.VehicleNo,  
        vm.LoadingCapacityKG,  
  
        rf.RevenueExclGST,  
        rf.GSTAmount,  
        rf.RevenueInclGST,  
        CASE WHEN rf.RevenueExclGST IS NOT NULL AND ISNULL(bd.ChargedWeightKG, 0) > 0 THEN ROUND(rf.RevenueExclGST / NULLIF(bd.ChargedWeightKG / 1000.0, 0), 2) ELSE NULL END AS RevenuePerMT,
  
        ISNULL(lca.AllocatedLinehaulCost, 0) AS AllocatedLinehaulCost,  
  
        bd.EDD,  
        rf.FinalEDD,  
        bd.DeliveryDate,  
        dl.AttemptDate,  
  
        -- Dynamic SLA Matrix
        CASE  
            WHEN bd.DeliveryDate IS NOT NULL AND bd.DeliveryDate <= rf.FinalEDD THEN 'On-Time'  
            WHEN bd.DeliveryDate IS NOT NULL AND bd.DeliveryDate > rf.FinalEDD THEN 'SLA Breach'  
            WHEN bd.DeliveryDate IS NULL AND dl.AttemptDate IS NOT NULL AND dl.AttemptDate > rf.FinalEDD THEN 'SLA Breach'  
            WHEN bd.DeliveryDate IS NULL AND GETDATE() > rf.FinalEDD THEN 'SLA Breach'  
            ELSE 'In-Transit'  
        END AS SLAStatus,  
  
        CASE WHEN bd.DeliveryDate IS NOT NULL THEN DATEDIFF(DAY, bd.ShipmentDate, bd.DeliveryDate) ELSE DATEDIFF(DAY, bd.ShipmentDate, GETDATE()) END AS ActualTransitDays,  
  
        -- Ageing Buckets for Receivables
        bs.BillNumber,  
        bs.BillDate,  
        ISNULL(bs.BillGrandTotal, 0) AS BillGrandTotal,  
        ISNULL(bs.BillBalanceCollectable, 0) AS OutstandingAmount,  
        CASE   
            WHEN bs.BillID IS NULL THEN 'Unbilled'  
            WHEN bs.BillBalanceCollectable <= 0 THEN 'Closed / Paid'  
            WHEN DATEDIFF(DAY, bs.BillDate, GETDATE()) <= 5 THEN '0 - 5 Days'  
            WHEN DATEDIFF(DAY, bs.BillDate, GETDATE()) BETWEEN 6 AND 10 THEN '6 - 10 Days'  
            WHEN DATEDIFF(DAY, bs.BillDate, GETDATE()) BETWEEN 16 AND 30 THEN '16 - 30 Days'  
            ELSE '> 30 Days'  
        END AS PendingBillAgeing  
  
    FROM Base_Shipment bd  
    LEFT JOIN Revenue_Final rf ON bd.ShipmentNo = rf.ShipmentNo  
    LEFT JOIN Delivery_Run_Latest dl ON bd.ShipmentNo = dl.ShipmentNo  
    LEFT JOIN dim_vehicle vm ON bd.VehicleNumberID = vm.ID  
    LEFT JOIN dim_branch ob ON bd.OriginBranchId = ob.ID  
    LEFT JOIN dim_branch db ON bd.DestBranchId = db.ID  
    LEFT JOIN Linehaul_Cost_Allocation lca ON bd.ShipmentNo = lca.ShipmentNo  
    LEFT JOIN Billing_Support bs ON bd.ShipmentNo = bs.ShipmentNo;
END;
GO
