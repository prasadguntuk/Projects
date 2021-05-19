/*------------------------------------------------------------------------------------
Author:       Abhishek Chaturvedi 
Company:      Arxxus Technology Partners 
Description:  This class gets events from trigger routed to it and calls the 
              appropriate class to handle the events
History
Date           Author             Comments 
--------------------------------------------------------------------------------------
14-03-2018     Abhishek Chaturvedi       Initial Release
26-06-2018     Sagar Avate               Added ApplicationTrancheManager in after insert call to 
                                         add default tranche on Loan Application creation.
7-01-2019      Manasi Londhe             creating tranche(s) in 'after insert'  
27-03-2019     Surbhi Bhati              written stage change code to central ops
31/07/2019     MD                        Fix added for D-001910 at 8.30PM by MD. 
                                         Reset Eligible Loan Amount on Program Type Change
06-09-2019	  Shubham Athalye			Update flag consider for eligibility on Obligation if Program type is changes
------------------------------------------------------------------------------------*/
public class OpportunityTriggerHandler implements ITriggerHandler {

    private list<String> activitiesToResetOnProgramTypeChange = new list<String> {'Segmentation', 'Eligibility'};
    private final static String OPPORTUNITY_DEFAULT_RECORD_TYPE_DEVELOPER_NAME = 'Default';

    public void beforeInsert(List<Opportunity> nOpportunities) {
        //populate Primary Sales and Primary Credit text fields
        this.updatePrimaryUserNames(nOpportunities);
        
        this.setProcessingBranch(nOpportunities);
        this.setProductMappingReference(nOpportunities);
        calculateEMI(nOpportunities);
        // Update Product lookup based on the value chosen in Product Name picklist
        updateProduct(nOpportunities);
    }
    
    public void beforeUpdate(Map<Id, SObject> nOpportunities, Map<Id, SObject> oOpportunities) {
        //populate Primary Sales and Primary Credit text fields 
        Map<Id,Opportunity> newOpps = (Map<Id,Opportunity>)nOpportunities;
        Map<Id,Opportunity> oldOpps = (Map<Id,Opportunity>)oOpportunities;
       //system.debug('newOpps-->' + newOpps);
        //update approvedLoanAmountWithPremium
        updateApprovedLoanAmountWithPremium(newOpps,oldOpps);
        //update 'Reject POD Update date' on update of 'POD number'
        updateRejectPODUpdatedate(newOpps,oldOpps);
        
        updatePrimaryUserNames(newOpps,oldOpps);

        if(!TriggerEventRouter.possibleRecursiveCallInTransaction) {
            this.restrictManualStageUpdation(nOpportunities, oOpportunities);
            this.restrictManualNameUpdation(nOpportunities, oOpportunities);
            this.restrictManualOwnerUpdation(nOpportunities, oOpportunities);
        }
        this.populateOppsStageTimestamps(nOpportunities,oOpportunities);
        this.setProcessingBranch(nOpportunities.values());
        this.setProductMappingReference(nOpportunities.values());
        calculateEMI(nOpportunities.values());
        // Update Product lookup based on the value chosen in Product Name picklist
        updateProduct((Map<Id,Opportunity>)nOpportunities,(Map<Id,Opportunity>)oOpportunities);
        //update Process type basis change in Program type from PreApproved to Full Underwriting
        updateProcessType((Map<Id,Opportunity>)nOpportunities,(Map<Id,Opportunity>)oOpportunities);
        resetFieldsAndActivitiesOnProgramTypeChange((Map<Id,Opportunity>)nOpportunities,(Map<Id,Opportunity>)oOpportunities);
    
    	//Update Financial Detail Record based on Obligation to Total_Obligations_To_Consider__c
        updateFinancialDetailRecordOnObligationUpdate((Map<Id,Opportunity>)nOpportunities,(Map<Id,Opportunity>)oOpportunities);

        // Update the processed stages
        addProcessedStage(nOpportunities, oOpportunities);
    }
    
    public void beforeDelete(Map<Id, SObject> oOpportunities) {
        
    }
    
    public void afterInsert(Map<Id, SObject> nOpportunities) {
       //create primary tranche
       System.debug('in after insert');
        insertRatiosAndTriggers(nOpportunities.keySet());
        updateGSTINOnApplicantAndAddress((List<Opportunity>)nOpportunities.values(),NULL);
       //DocumentTriggerEntryCriteria.insertDocuments(nOpportunities);
      //new ManualVerificationHandler().raise(nOpportunities);
    }
    
    public void afterUpdate(Map<Id, SObject> nOpportunities, Map<Id, SObject> oOpportunities) {

        Map<Id,Opportunity> newRecords = (Map<Id,Opportunity>)nOpportunities;
        Map<Id,Opportunity> oldRecords = (Map<Id,Opportunity>)oOpportunities;
        //added for stage change to central ops 
        Set<Id> response = new Set<Id>();
        String activityHandlerName ;
        set<Opportunity> loanApplicationsTrancheToUpdate = new set<Opportunity>();
        Map<Id, Opportunity> idVsLoanApplication = new Map<Id, Opportunity>();
        Set<Id> loanIds = new Set<Id>();
        Set<String> loanStages = new Set<String>();
        Map<String,Workflow_Activity__c> loanIdVsWorkflowActivity = new Map<String,Workflow_Activity__c>();
        for(Opportunity newOpp : newRecords.values()){
            loanIds.add(newOpp.Id);
            loanStages.add(newOpp.StageName);
            if(newOpp.Loan_Variant__c != oldRecords.get(newOpp.Id).Loan_Variant__c 
                || newOpp.Approved_Loan_Amount__c != oldRecords.get(newOpp.Id).Approved_Loan_Amount__c){
                loanApplicationsTrancheToUpdate.add(newOpp);
            }    
        }
        
        if(loanApplicationsTrancheToUpdate.size() > 0) {
            Map<Id,Tranche__c> loanApplicationIdVsTranche=new Map<Id,Tranche__c>();
            List<Tranche__c> tranchesToUpdate=new List<Tranche__c>();
            for(Tranche__c tranche: [Select Id, (Select Id,Loan_Variant__c,Tranche_Number__c,Loan_Application__c From Child_tranches__r Where Tranche_Number__c='1') 
                                        From Opportunity Where Id In : loanApplicationsTrancheToUpdate].Child_tranches__r){
                    loanApplicationIdVsTranche.put(tranche.Loan_Application__c, new Tranche__c(Id = tranche.Id, 
                                                                                                Loan_Variant__c = newRecords.get(tranche.Loan_Application__c).Loan_Variant__c,
                                                                                                Current_Context_User__c = 'Automated Process'));
            }
            if(loanApplicationIdVsTranche.size() > 0) {
                System.debug('--loanApplicationIdVsTranche--' + loanApplicationIdVsTranche);
                TriggerEventRouter.stopTriggerExecution = true;
                update loanApplicationIdVsTranche.values();
                TriggerEventRouter.stopTriggerExecution = false;

            }
        }

        syncDataWithOffer(newRecords, oldRecords);
        FinancialDetailUnsecuredHelper.deleteFinancialDetailsWhenProgTypeChanged(nOpportunities,oOpportunities);
        updateBankBTOPercentOnProgramTypeChange(nOpportunities,oOpportunities);
        //calling loanDisbursalHandler class 
        response = checkFinnoneUploadStatusUpdated(newRecords, oldRecords);
        System.debug('response is'+ response);
        if(!response.isEmpty()){
            String loanIdsString = ''; 
            for(Id loanId : response){
                loanIdsString = loanIdsString + loanId + ',';
                loanIdsString.removeEnd(',');
            }
            EventBus.publish(new Finnone_Reverse_Update__e(Loan_Application_Ids__c = loanIdsString));
        }
        system.debug('Reached here 1');
        //Update flag consider for eligibility on Obligation if Program type is changes
        updateObligationOnProgramTypeChange(newRecords, oldRecords);
        system.debug('Reached here 2');
        updateGSTINOnApplicantAndAddress(newRecords.values(),oldRecords);
        
        //D-002318 Perform FMS if the stage is changed to 'Central Ops
        String performCallout = Label.Perform_FMS_Callout;
        if(performCallout.equalsIgnoreCase('true'))
        	performFMSCallout((Map<Id,Opportunity>)nOpportunities,(Map<Id,Opportunity>)oOpportunities);
    }
    
    public void afterDelete(Map<Id, SObject> oOpportunities) {
        
    }
    
    public void afterUndelete(Map<Id, SObject> oOpportunities) {
        
    }
    
    public boolean permit(TriggerEventRouter.TriggerContext tContext) {
        System.debug('--trigger context opp handler--' + tContext);
        return true;
    }
    
    public boolean isDisabled() {
        return false;
    }
    
    private void insertRatiosAndTriggers(Set<Id> loanApplicationIds){
        List<String> consolidatedRatioParameters=new List<String>{
            'Capital (in lacs)',
            'Reserves and Surplus (In lacs)',
            'TotalExistingBorrowingsexccldOD/C(Lac)',
            'Total Creditors (in lacs)',
            'Total Debtors (In lacs)',
            'Closing Stock (in lacs)',
            'Bank Cash Balance ( In Lacs)',
            'Balance Sheet Total (In lacs)',
            'Sales Turnover (In Lacs)',
            'Net Profit (In lacs)',
            'Depreciation (In Lacs)',
            'Net Profit margin %',
            'Total Net Worth (In lacs)',
            'Current Ratio',
            'Total Working capital (lacs)',
            'Cash conversion cycle (in days)',
            'Debtor turnover (in days)',
            'Creditor turnover (in days)',
            'Stock turnover (in days)',
            'Total existing borrowing to Sales (in%)',
            'Cash Profit (Lacs)',
            'Obligation To Turnover Ratio',
            'Average OD/CC utilization %',
            'BTO%',
            'EMI Bounce',
            'Inward Bounce Count',
            'OD CC Limit(In Lacs)',
            'BTO(In Lacs)',
            'Inward bounce in %'
        };
        //List<String> consolidatedRatioParameters= new List<String>();
        /*Schema.DescribeFieldResult fieldResult = Triggers_And_Ratios__c.Parameter__c.getDescribe();
        List<Schema.PicklistEntry> picklistValues = fieldResult.getPicklistValues();
        for( Schema.PicklistEntry pickListVal : picklistValues){
            consolidatedRatioParameters.add(pickListVal.getLabel());
        }*/
        //insert dummy consolidated ratio records for each ratio parameter.
        Id financialRecordTypeId=Schema.SObjectType.Triggers_And_Ratios__c.getRecordTypeInfosByName().get('Financial Details').getRecordTypeId();
        List<Triggers_And_Ratios__c> dummyRatiosRecordsToInsert=new List<Triggers_And_Ratios__c>();
        for(String param:consolidatedRatioParameters){
            for(Id loanApplicationId:loanApplicationIds){
                Triggers_And_Ratios__c ratioRecord=new Triggers_And_Ratios__c(loan_Application__c=loanApplicationId,
                                                                             Parameter__c=param,
                                                                             RecordTypeId=financialRecordTypeId);
                 dummyRatiosRecordsToInsert.add(ratioRecord);
            }
        }
        insert dummyRatiosRecordsToInsert;
    }
    
    private void updateBankBTOPercentOnProgramTypeChange(Map<Id, SObject> nOpportunities, Map<Id, SObject> oOpportunities){
         Set<Id> loansWithUpdatedProgType = new Set<Id>();
         for(Opportunity updatedLoanApplication : (List<Opportunity>)nOpportunities.values()) {
             if(updatedLoanApplication.Program_Type__c != ((Opportunity)oOpportunities.get(updatedLoanApplication.Id)).Program_Type__c && updatedLoanApplication.Program_Type__c != null) {
                loansWithUpdatedProgType.add(updatedLoanApplication.Id);
             }
       	}
        BankingProgramTypeValidator.runValidations = false;
        FinancialDetailUnsecuredHelper.updateBankBTOPercent(loansWithUpdatedProgType);
        BankingProgramTypeValidator.runValidations = true;
        
    }
    
    private void updatePrimaryUserNames(List<Opportunity> nOpportunities){
        Set<Id> urmIDs = new Set<Id>();
        for(Opportunity newOpp : nOpportunities){
            if(String.isNotBlank(newOpp.Primary_Sales_User__c))urmIDs.add(newOpp.Primary_Sales_User__c);
            if(String.isNotBlank(newOpp.Primary_Credit_User__c))urmIDs.add(newOpp.Primary_Credit_User__c);
            if(String.isNotBlank(newOpp.Primary_Pre_Sales_User__c))urmIDs.add(newOpp.Primary_Pre_Sales_User__c);// Added by Needhi for Mobility
            if(String.isNotBlank(newOpp.Branch_Ops_Checker__c))urmIDs.add(newOpp.Branch_Ops_Checker__c);// Added by Needhi for Mobility
            if(String.isNotBlank(newOpp.Branch_Ops__c))urmIDs.add(newOpp.Branch_Ops__c);// Added by Needhi for Mobility
        }
        
        if(!urmIDs.isEmpty()){
            Map<String,User_Role_Master__c> userRoleMaster = new Map<String,User_Role_Master__c>([SELECT Id,Name,User_ID__r.Name,User_ID__r.FirstName,User_ID__r.LastName 
                                                                                                    FROM User_Role_Master__c
                                                                                                   WHERE Id IN: urmIDs]);
            populatePrimaryUserNames(nOpportunities,userRoleMaster);
        }
    }
    
    private void updatePrimaryUserNames(Map<Id,Opportunity> newOppMap, Map<Id,Opportunity> oldOpps){
        Set<Id> urmIDs = new Set<Id>();
        for(Opportunity newOpp : (List<Opportunity>)newOppMap.values()){
            if( newOpp.Primary_Sales_User__c != null
                && newOpp.Primary_Sales_User__c != oldOpps.get(newOpp.Id).Primary_Sales_User__c){
                urmIDs.add(newOpp.Primary_Sales_User__c);
            }
            if(newOpp.Primary_Credit_User__c != null 
                && newOpp.Primary_Credit_User__c != oldOpps.get(newOpp.Id).Primary_Credit_User__c){
                urmIDs.add(newOpp.Primary_Credit_User__c);
            }
        }
        
        if(!urmIDs.isEmpty()){
            Map<String,User_Role_Master__c> userRoleMaster = new Map<String,User_Role_Master__c>([SELECT Id,Name,User_ID__r.Name,User_ID__r.FirstName,User_ID__r.LastName 
                                                                                                    FROM User_Role_Master__c
                                                                                                   WHERE Id IN: urmIDs]);
            populatePrimaryUserNames(newOppMap.values(),userRoleMaster);
        }
    }
    
    private void populatePrimaryUserNames(List<Opportunity> nOpportunities, Map<String,User_Role_Master__c> userRoleMaster){
        for(Opportunity newOpp : nOpportunities){
            if(userRoleMaster.containsKey(newOpp.Primary_Sales_User__c)) newOpp.Primary_Sales_User_Name__c = userRoleMaster.get(newOpp.Primary_Sales_User__c).User_ID__r.Name;
            if(userRoleMaster.containsKey(newOpp.Primary_Credit_User__c)) newOpp.Primary_Credit_User_Name__c = userRoleMaster.get(newOpp.Primary_Credit_User__c).User_ID__r.Name;
            if (userRoleMaster.containsKey(newOpp.Primary_Pre_Sales_User__c)) newOpp.Primary_PreSales_User_Name__c = userRoleMaster.get(newOpp.Primary_Pre_Sales_User__c).User_ID__r.Name; // Added by Needhi for Mobility
            if (userRoleMaster.containsKey(newOpp.Branch_Ops__c)) newOpp.BranchOpsUser__c = userRoleMaster.get(newOpp.Branch_Ops__c).User_ID__r.Name; // Added by Needhi for Mobility
            if (userRoleMaster.containsKey(newOpp.Branch_Ops_Checker__c)) newOpp.BranchOpsCheckerUser__c = userRoleMaster.get(newOpp.Branch_Ops_Checker__c).User_ID__r.Name; // Added by Needhi for Mobility
        }
    }

    //Stamp Initial/ Last submitted to Opps status
    private void populateOppsStageTimestamps(Map<Id, SObject> nOpportunities, Map<Id, SObject> oOpportunities) {
        for(Opportunity op : (list<Opportunity>) nOpportunities.values()){
            if(op.StageName != ((String) oOpportunities.get(op.Id).get('StageName')) 
                && op.StageName == GlobalConstants.STAGE_PSF_BRANCH_OPS) {
                System.debug('--Stamping Opss TimeStamps--');
                op.Last_Submitted_to_Branch_Ops__c = Datetime.now();
                if(op.Initial_File_Submitted_to_Branch_Ops__c == NULL) {
                    op.Initial_File_Submitted_to_Branch_Ops__c = Datetime.now();
                }
            }
        }
    }
	
    //D-002318 Perform FMS if the stage is changed to 'Central Ops'
    private void performFMSCallout(Map<Id, SObject> newRecords, Map<Id, SObject> oldRecords) {
        
        for(Opportunity loan : (List<Opportunity>)newRecords.values()) {
            if(loan.stagename == 'Central Ops'
               && loan.stagename != ((Opportunity)oldRecords.get(loan.Id)).stagename) {
                FMSCalloutClass.invokeFMSService(loan.Id);
            }
        }
    }
    
    //D-002038 Update obligation @shubham
    //If program type is RTR then mark consider for eligibility as true for all obligation which are created from cibil
    //if program type is anything else other than RTR then mark consider for eligibility as true only for Live obligations
    private void updateObligationOnProgramTypeChange(Map<Id, SObject> newRecords, Map<Id, SObject> oldRecords) {
        
        SET<String> programTypeChangedLoanIds = new SET<String>();
        for(Opportunity loan : (List<Opportunity>)newRecords.values()) {
            if(loan.Program_Type__c != null && loan.Program_Type__c != ((Opportunity)oldRecords.get(loan.Id)).Program_Type__c) {
                programTypeChangedLoanIds.add(loan.Id);
            }
        }
        
        if(programTypeChangedLoanIds.size() > 0) {
            
            List<Opportunity> programTypeChangedLoans = [SELECT Id, Program_Type__r.Program_Type__c, 
                                                         (SELECT Id, Consider_for_eligibility__c, Status__c FROM Obligations__r WHERE From_Cibil__c = true)
                                                         FROM Opportunity WHERE Id IN :programTypeChangedLoanIds];
            List<Obligation__c> obligationsToUpdate = new List<Obligation__c>();
            
            
            for(Opportunity loan : programTypeChangedLoans) {
                
                System.debug('programTypeChangedLoans' + loan.Program_Type__r.Program_Type__c );
                for(Obligation__c obligation : loan.Obligations__r) {
                    
                    obligation.Intent__c =  '{"context": "UPDATED_FROM_LOAN"}';
                    if(loan.Program_Type__r.Program_Type__c == 'RTR') {
                  
                        System.debug('obligation >>' + obligation);
                        if(!obligation.Consider_for_eligibility__c) {
                            obligation.Consider_for_eligibility__c = true;
                            obligationsToUpdate.add(obligation);
                        }
    				} else {
                        
                        if(obligation.Consider_for_eligibility__c && !obligation.Status__c.equalsIgnoreCase('Live')) {
                            obligation.Consider_for_eligibility__c = false;
                            obligationsToUpdate.add(obligation);
                        } else if(!obligation.Consider_for_eligibility__c && obligation.Status__c.equalsIgnoreCase('Live')) {
                            obligation.Consider_for_eligibility__c = true;
                            obligationsToUpdate.add(obligation);
                        }
                    } 
                }
            }
            
            System.debug('obligationsToUpdate >>' + obligationsToUpdate);
            if(obligationsToUpdate.size() > 0)
                update obligationsToUpdate;
        }
    }
    
    //Aakash - Restrict user from updating stage field manually
    private void restrictManualStageUpdation(Map<Id, SObject> nOpportunities, Map<Id, SObject> oOpportunities){
        Map<Id,Opportunity> newRecords = (Map<Id,Opportunity>)nOpportunities;
        Map<Id,Opportunity> oldRecords = (Map<Id,Opportunity>)oOpportunities;

        String profileName;
        if(UserInfo.getName().containsIgnoreCase('automated')) profileName = 'System Administrator';
        else profileName = GlobalUtility.getRunningUserProfileName();

        for(Opportunity op : newRecords.values()){
            System.debug('--Opp Stage--' + op.StageName + '--' + oldRecords.get(op.Id).StageName);
            Boolean intentVerified = verifyIntentForStageChange(op);
            if(op.StageName != oldRecords.get(op.Id).StageName
                && profileName != 'System Administrator'){ // Allow to change stage if done by Sys Admin
                if(!intentVerified) op.addError('You are not authorized to change the stage manually.');
            }
        }
    }

    private static Boolean verifyIntentForStageChange(Opportunity loanApplication){
        System.debug('Intent->' + loanApplication.Intent__c + '--' + TriggerEventRouter.getIntent(loanApplication.Intent__c));
        Map<String, Object> intentMap = new Map<String, Object>();
        if(loanApplication.Intent__c != null
            && TriggerEventRouter.getIntent(loanApplication.Intent__c) != null){
            
            intentMap = (Map<String, Object>)JSON.deserializeUntyped(TriggerEventRouter.getIntent(loanApplication.Intent__c));
            if(intentMap.containsKey('context')
                && intentMap.get('context') == 'UI_NEXT_STAGE_CLICK'){
                return true;
            }
            return false;
        }
        return false;
    }
    
    private void restrictManualOwnerUpdation(Map<Id, SObject> nOpportunities, Map<Id, SObject> oOpportunities){
        System.debug('restrict manual owner updation');
        Map<Id,Opportunity> newRecords = (Map<Id,Opportunity>)nOpportunities;
        Map<Id,Opportunity> oldRecords = (Map<Id,Opportunity>)oOpportunities;

        String profileName;
        if(UserInfo.getName().containsIgnoreCase('automated')) profileName = 'System Administrator';
        else profileName = GlobalUtility.getRunningUserProfileName();

        for(Opportunity op : newRecords.values()){
            System.debug('--Opp Stage--' + op.StageName + '--' + oldRecords.get(op.Id).StageName);
            Boolean intentVerified = verifyIntentForOwnerChange(op);
            if(op.OwnerId != oldRecords.get(op.Id).OwnerId
                && profileName != 'System Administrator'){ // Allow to change stage if done by Sys Admin
                if(!intentVerified) op.addError('You are not authorized to change the owner manually.');
            }
        }
    }

    private static Boolean verifyIntentForOwnerChange(Opportunity loanApplication){
        System.debug('Intent->' + loanApplication.Intent__c + '--' + TriggerEventRouter.getIntent(loanApplication.Intent__c));
        Map<String, Object> intentMap = new Map<String, Object>();
        if(loanApplication.Intent__c != null
            && TriggerEventRouter.getIntent(loanApplication.Intent__c) != null){
            
            intentMap = (Map<String, Object>)JSON.deserializeUntyped(TriggerEventRouter.getIntent(loanApplication.Intent__c));
            if(intentMap.containsKey('ownwerChangeIntent')
                && intentMap.get('ownwerChangeIntent') == 'OWNER_CHANGE'){
                return true;
            }
            return false;
        }
        return false;
    }


    //Shubham - Restrict user from updating Loan Application Name
    private void restrictManualNameUpdation(Map<Id, SObject> nOpportunities, Map<Id, SObject> oOpportunities){
        Map<Id,Opportunity> newRecords = (Map<Id,Opportunity>)nOpportunities;
        Map<Id,Opportunity> oldRecords = (Map<Id,Opportunity>)oOpportunities;

        String profileName;
        if(UserInfo.getName().containsIgnoreCase('automated')) profileName = 'System Administrator';
        else profileName = GlobalUtility.getRunningUserProfileName();

        for(Opportunity op : newRecords.values()){
            System.debug('--Opp Stage--' + op.StageName + '--' + oldRecords.get(op.Id).StageName);
            Boolean intentVerified = verifyIntentForNameChange(op);
            if(op.Name != oldRecords.get(op.Id).Name
                && profileName != 'System Administrator'){ // Allow to change name if done by Sys Admin
                if(!intentVerified) op.addError('You are not authorized to change the Name manually.');
            }
        }
    }

    private static Boolean verifyIntentForNameChange(Opportunity loanApplication){
        System.debug('Intent->' + loanApplication.Intent__c + '--' + TriggerEventRouter.getIntent(loanApplication.Intent__c));
        Map<String, Object> intentMap = new Map<String, Object>();
        if(loanApplication.Intent__c != null
            && TriggerEventRouter.getIntent(loanApplication.Intent__c) != null){
            
            intentMap = (Map<String, Object>)JSON.deserializeUntyped(TriggerEventRouter.getIntent(loanApplication.Intent__c));
            if(intentMap.containsKey('context')
                && intentMap.get('context') == 'UI_NAME_CHANGED'){
                return true;
            }
            return false;
        }
        return false;
    }
    /*
    * @Author: Trupti Deshpande
    * @Description: This method will set the processing branch. It will be same as the sourcing branch.
    */
    private void setProcessingBranch(List<Opportunity> loanApplications) {
        for(Opportunity loanApplication : loanApplications) {
            if(String.isNotBlank(loanApplication.Sourcing_Branch__c))
            loanApplication.Processing_Branch__c = loanApplication.Sourcing_Branch__c;
        }
    }
    
    /*
    * @Author: Trupti Deshpande
    * @Description: EMI calculation
    */
    public void calculateEMI(List<Opportunity> opportunities) {
        if(trigger.isUpdate)
        Approval.unlock(opportunities);
        for(Opportunity opp : opportunities) {
            opp.EMI_In_Rs__c = GlobalUtility.calculateEMI(
                                                            opp.Requested_Loan_Amount__c != Null ? Double.valueOf(opp.Requested_Loan_Amount__c) : 0.0, 
                                                            opp.Requested_ROI_In_Percentage__c != Null ? Double.valueOf(opp.Requested_ROI_In_Percentage__c) : 0.0, 
                                                            opp.Requested_Loan_tenor__c != Null ? Double.valueOf(opp.Requested_Loan_tenor__c) : 0.0);
        }
    }

    //This method will update the Product Master Lookup
    public void updateProduct(Map<Id, Opportunity> newLoans, Map<Id, Opportunity> oldLoans){
        List<Opportunity> applicableLoans = new List<Opportunity>();
        for(Opportunity op : newLoans.values()){
            if(op.Product_Name__c != oldLoans.get(op.Id).Product_Name__c 
                || op.Offer_product__c != oldLoans.get(op.Id).Offer_product__c ){
                applicableLoans.add(op);
            }
        }
        if(!applicableLoans.isEmpty()) updateProduct(applicableLoans);
    }

    //This method will update the Product Master Lookup
    public void updateProduct(List<Opportunity> newLoans){
        Map<String,Product_Master__c> productNameVsProductMaster = getNameVsProductMaster(newLoans);
        if(productNameVsProductMaster != null){
            for(Opportunity op : newLoans){
                if(op.Product_Name__c != null 
                   && productNameVsProductMaster.containsKey(op.Product_Name__c)
                   && productNameVsProductMaster.get(op.Product_Name__c) != NULL){
                    op.Offer_product__c = productNameVsProductMaster.get(op.Product_Name__c).Id;
                        if(productNameVsProductMaster.get(op.Product_Name__c).Opportunity_Record_Type__c != NULL 
                        && Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get(productNameVsProductMaster.get(op.Product_Name__c).Opportunity_Record_Type__c) != NULL) {
                        op.RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get(productNameVsProductMaster.get(op.Product_Name__c).Opportunity_Record_Type__c).getRecordTypeId();
                    } else {
                        //Stamp default record type
                        op.RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get(OPPORTUNITY_DEFAULT_RECORD_TYPE_DEVELOPER_NAME).getRecordTypeId();
                    }
                }
            }
        }
    }

    public Map<String,Product_Master__c> getNameVsProductMaster(List<Opportunity> loanApps){
        Map<String,Product_Master__c> productNameVsProductMaster = new Map<String,Product_Master__c>();
        Set<String> productNames = new Set<String>();
        for(Opportunity op : loanApps){
            if(op.Product_Name__c != null) productNames.add(op.Product_Name__c);
        }

        if(productNames == null) return null;
        for(Product_Master__c productMaster :  [SELECT Id,Product_Name__c,Opportunity_Record_Type__c
                                                FROM Product_Master__c
                                                WHERE Product_Name__c IN: productNames]){
            productNameVsProductMaster.put(productMaster.Product_Name__c,productMaster);
        }
        return productNameVsProductMaster;
    }

    /** populate Product Mapping Master based on Branch and Product configured in master.  there must be single row in Product Mapping Master for each Sourcing Branch on Loan Application.*/
    public void setProductMappingReference(List<Opportunity> nOpportunities)  {
        Map<String, Product_Mapping_Master__c> productms = new Map<String, Product_Mapping_Master__c>();
        Set<String> branchNames = new Set<String>();
        Set<String> products = new Set<String>();
        for(Opportunity loanApplication : nOpportunities)  {
            if(String.isNotBlank(loanApplication.Sourcing_Branch__c)) branchNames.add(loanApplication.Sourcing_Branch__c);
            if(String.isNotBlank(loanApplication.Offer_Product__c)) products.add(loanApplication.Offer_Product__c);
        }
        
        if(branchNames.isEmpty() || products.isEmpty()) return;
        
        for(Product_Mapping_Master__c productm : [SELECT Id, Product__c, Product__r.Product_Name__c, Branch_Name__c 
                                                    FROM Product_Mapping_Master__c
                                                    WHERE Mapping_type__c =: GlobalConstants.MAPPING_TYPE_BRANCH
                                                 	AND Branch_Name__c IN : branchNames
                                                 	AND Product__c IN : products]){
            productms.put(productm.Branch_Name__c+'-'+productm.Product__c, productm);
        }
        for(Opportunity loanApplication : nOpportunities)  {
            if(productms.containsKey(loanApplication.Sourcing_Branch__c+'-'+loanApplication.Offer_Product__c))  {
                loanApplication.Product_Mapping_Master__c = productms.get(loanApplication.Sourcing_Branch__c+'-'+loanApplication.Offer_Product__c).Id;
            }
        }
    }

    /*
    *   This method will sync the Opportunity Stage with Lead Offering stage from where it was converted
    *   Add the relevent fields to be syced in offersToSync.add method.
    */
    private void syncDataWithOffer(Map<Id, Opportunity> newLoans, Map<Id, Opportunity> oldLoans) {
        list<Lead> offersToSync = new list<Lead>();
        for(Opportunity loanApplication : newLoans.values()) {
            if(newLoans.get(loanApplication.Id).StageName != oldLoans.get(loanApplication.Id).StageName && loanApplication.Lead_Offering__c != null) {
                offersToSync.add(new Lead(Id = loanApplication.Lead_Offering__c, Status = loanApplication.StageName));
            }   
        }

        if(offersToSync.size() > 0)
            Database.update(offersToSync);
    }

    //update Process type basis change in Program type from PreApproved to Full Underwriting
    private void updateProcessType(Map<Id, Opportunity> nOpportunities,Map<Id, Opportunity> oOpportunities){
        list<Opportunity> qOpportunities = new list<Opportunity>();
        for(Opportunity loan : oOpportunities.values()){
            if(loan.Program_Type__c != nOpportunities.get(loan.Id).Program_Type__c){
                qOpportunities.add(nOpportunities.get(loan.Id));
            }
        }

        if(qOpportunities.size() > 0) {
            List<Common_Master__c> preApprovedProgramId = [SELECT Id 
                                                            FROM Common_Master__c 
                                                            WHERE Program_Type__c = 'Pre Approved'
                                                            AND RecordType.DeveloperName =: GlobalConstants.COMMON_MASTER_RECORD_TYPE_PROGRAM_TYPES 
                                                            LIMIT 1];
            if(preApprovedProgramId.isEmpty()) return;
            for(Opportunity loanApplication : qOpportunities) {
                if(loanApplication.Program_Type__c == preApprovedProgramId[0].Id) {
                    loanApplication.Process_Type__c = GlobalConstants.FULL_UNDERWRITING_PROCESS_TYPE;
                }
            }
        }
    }
    // Adding for loanDisbursalHandler class

    private Set<Id> checkFinnoneUploadStatusUpdated(Map<Id, Opportunity> newLoans, Map<Id, Opportunity> oldLoans){
        System.debug('In checkFinnoneUploadStatusUpdated ' );
        Set<Id> loanIds = new Set<Id>();
        for(Opportunity loan : newLoans.values()){
            if(loan.Moved_To_Finnone__c == GlobalConstants.MOVED_TO_FINNONE_SUCCESS && loan.Moved_To_Finnone__c != oldLoans.get(loan.Id).Moved_To_Finnone__c){
               loanIds.add(loan.Id);
            }  
        }
        System.debug('Set of loan ids' + loanIds); 
        return loanIds;
    }
    
    public void updateRejectPODUpdatedate(Map<Id,Opportunity> newOpps,Map<Id,Opportunity> oldOpps){
         for(Opportunity opp:newOpps.values()){
            if(opp.POD_Number__c!=oldOpps.get(opp.Id).POD_Number__c
                && opp.Loan_Status__c == GlobalConstants.LOAN_APPLICATION_STATUS_REJECTED){
                opp.Reject_POD_Update_Date__c=system.today();
            }
         }
    }
    
    //update loan amount with premium if approved loan amount is updated
    public void updateApprovedLoanAmountWithPremium(Map<Id,Opportunity> newOpps,Map<Id,Opportunity> oldOpps){
         for(Opportunity opp:newOpps.values()){
            if(opp.Approved_Loan_Amount__c!=oldOpps.get(opp.Id).Approved_Loan_Amount__c){
                if(opp.Approved_loan_amount_with_premium__c!=null && opp.Approved_loan_amount_with_premium__c!=0 && opp.Approved_loan_amount_with_premium__c>=oldOpps.get(opp.Id).Approved_Loan_Amount__c){
                   opp.Approved_loan_amount_with_premium__c=(opp.Approved_loan_amount_with_premium__c-oldOpps.get(opp.Id).Approved_Loan_Amount__c)+opp.Approved_Loan_Amount__c;
                }
                else if(opp.Approved_loan_amount_with_premium__c==null){
                    opp.Approved_loan_amount_with_premium__c=opp.Approved_Loan_Amount__c;
                }
            }
         }
    }
    
    @testVisible
    private void resetFieldsAndActivitiesOnProgramTypeChange(Map<Id,Opportunity> newMap, Map<Id,Opportunity> oldMap) {
        list<Opportunity> qOpportunities = new list<Opportunity>();
        
        for(Opportunity updatedLoanApplication : (List<Opportunity>)newMap.values()) {
            System.debug('-PT-' + updatedLoanApplication.Program_Type__c + '--' + oldMap.get(updatedLoanApplication.Id).Program_Type__c);
            if(updatedLoanApplication.Program_Type__c != ((Opportunity)oldMap.get(updatedLoanApplication.Id)).Program_Type__c
                && updatedLoanApplication.Program_Type__c != null) {
                qOpportunities.add(updatedLoanApplication);
                updatedLoanApplication.Current_Customer_Segment__c = null;
                
                if(updatedLoanApplication.Process_Type__c == GlobalConstants.FULL_UNDERWRITING_PROCESS_TYPE)//added this for D-00225
                	updatedLoanApplication.Eligible_loan_amount__c = 0; //Fix added for D-001910 on 31/07/2019 8.30PM by MD
            }
        }

        if(qOpportunities.size() > 0) { 
            list<Workflow_Activity__c> activitiesToReset = new list<Workflow_Activity__c>();
            //Activity_Hash_JSON__c, Activity_Hash_Value__c, ReAppraise_Activity_Hash_JSON__c, ReAppraise_Activity_Hash_Value__c
            for(Workflow_Activity__c wa: [Select Id, Opportunity__c, Stage__c 
                                          From Workflow_Activity__c 
                                          Where Opportunity__c IN: qOpportunities 
                                          And Canonical_Name__c IN: activitiesToResetOnProgramTypeChange]) {
                activitiesToReset.add(new Workflow_Activity__c(Id = wa.Id, 
                                                                Stage__c = GlobalConstants.WORKFLOW_ACTIVITY_STAGE_NEW, 
                                                                Activity_Hash_JSON__c = null,
                                                                Activity_Hash_Value__c = null,
                                                                ReAppraise_Activity_Hash_JSON__c = null,
                                                                ReAppraise_Activity_Hash_Value__c =  null));
            }

            if(activitiesToReset.size() > 0) {
                TriggerEventRouter.stopTriggerExecution = true;
                    update activitiesToReset;
                TriggerEventRouter.stopTriggerExecution = false;
            }
        }
    }
    
     /* Added By Shailja for Defect - 1932
     * @params : Old and New Opportunities Map
     * @Description: Method is responsible for updating Financial Detail record if Total_Obligations_To_Consider__c field changes in Loan Application
     */ 
     public void updateFinancialDetailRecordOnObligationUpdate(Map<Id, Opportunity> newOpptys, Map<Id, Opportunity> oldOpptys){
        List<Opportunity> optyToUpdateFd = new List<Opportunity>();
        for(Opportunity opty : newOpptys.values()){
            //If Total_Obligations_To_Consider__c changed
            if(opty.Total_Obligations_To_Consider__c != oldOpptys.get(opty.Id).Total_Obligations_To_Consider__c){
                optyToUpdateFd.add(opty);
            }
        }
        
        //Call FinancialDetailTriggerHandler method to update the Financial Detail Fields
        FinancialDetailTriggerHandler.calculateObligationToTurnOverRatioField(optyToUpdateFd);
    }
    
    private void updateGSTINOnApplicantAndAddress(List<Opportunity> newList, Map<Id,Opportunity> oldMap) {
        List<Applicant__c> applicantsToUpdate = new List<Applicant__c>();
        List<Address_Detail__c> addressToUpdate = new List<Address_Detail__c>();
        if(oldMap == NULL) {
            for(Opportunity loanApplication : newList) {
                if(String.isNotBlank(loanApplication.GSTIN__c) && loanApplication.Primary_Applicant__c != NULL) {
                    List<Address_Detail__c> priApplcntMailingAddress = [Select Id,GST_Address__c from Address_Detail__c where is_mailing_address__c = true AND Applicant__c =:loanApplication.Primary_Applicant__c LIMIT 1];
                    if(priApplcntMailingAddress != NULL && priApplcntMailingAddress.size() > 0) {
                        priApplcntMailingAddress[0].GST_Address__c = true;
                        addressToUpdate.add(priApplcntMailingAddress[0]);
                    }
                    Applicant__c primaryApplicant = new Applicant__c(Id = loanApplication.Primary_Applicant__c);
                    primaryApplicant.GSTIN__c = loanApplication.GSTIN__c;
                    primaryApplicant.Consider_for_Loan__c = GlobalConstants.CONSIDER_FOR_LOAN_YES;
                    primaryApplicant.GST_Exemption_Applicable__c = GlobalConstants.CONSIDER_FOR_LOAN_YES;
                    applicantsToUpdate.add(primaryApplicant);
                }
            }
        } else {
            for(Opportunity loanApplication : newList) {
                if(loanApplication.GSTIN__c != oldMap.get(loanApplication.Id).GSTIN__c) {
                    if(String.isNotBlank(loanApplication.GSTIN__c)) {
                       	List<Address_Detail__c> priApplcntMailingAddress = [Select Id,GST_Address__c from Address_Detail__c where is_mailing_address__c = true AND Applicant__c =:loanApplication.Primary_Applicant__c];
                    	if(priApplcntMailingAddress != NULL && priApplcntMailingAddress.size() > 0) {
                       		for(Address_Detail__c addrDetail : priApplcntMailingAddress) {
                        		addrDetail.GST_Address__c = true;
                        		addressToUpdate.add(addrDetail);
                    		} 
                    	}
                    	Applicant__c primaryApplicant = new Applicant__c(Id = loanApplication.Primary_Applicant__c);
                    	primaryApplicant.GSTIN__c = loanApplication.GSTIN__c;
                    	primaryApplicant.Consider_for_Loan__c = GlobalConstants.CONSIDER_FOR_LOAN_YES;
                    	primaryApplicant.GST_Exemption_Applicable__c = GlobalConstants.CONSIDER_FOR_LOAN_YES;
                    	applicantsToUpdate.add(primaryApplicant); 
                    } else {
                        List<Address_Detail__c> priApplcntMailingAddress = [Select Id,GST_Address__c from Address_Detail__c where is_mailing_address__c = true AND Applicant__c =:loanApplication.Primary_Applicant__c];
                    	if(priApplcntMailingAddress != NULL && priApplcntMailingAddress.size() > 0) {
                       		for(Address_Detail__c addrDetail : priApplcntMailingAddress) {
                        		addrDetail.GST_Address__c = false;
                        		addressToUpdate.add(addrDetail);
                    		} 
                    	}
                    	Applicant__c primaryApplicant = new Applicant__c(Id = loanApplication.Primary_Applicant__c);
                    	primaryApplicant.GSTIN__c = loanApplication.GSTIN__c;
                    	primaryApplicant.Consider_for_Loan__c = null;
                    	primaryApplicant.GST_Exemption_Applicable__c = null;
                    	applicantsToUpdate.add(primaryApplicant);
                    }
                }
            }
        }
        if(applicantsToUpdate != null && applicantsToUpdate.size() > 0) {
            TriggerEventRouter.stopTriggerExecution = true;
        	update applicantsToUpdate;
            TriggerEventRouter.stopTriggerExecution = false;
        }
        if(addressToUpdate != NULL && addressToUpdate.size() > 0 ) {
            TriggerEventRouter.stopTriggerExecution = true;
        	update addressToUpdate;
            TriggerEventRouter.stopTriggerExecution = false;
        }
    }

    /**
     * Method to populate LA stages that it has went throughout the processing journey
     * Added by Needhi mobility
     */
    private void addProcessedStage(Map<Id, SObject> nOpp, Map<Id, SObject> oOpp) {
        Map<Id,Opportunity> newRecords = (Map<Id,Opportunity>)nOpp;
        Map<Id,Opportunity> oldRecords = (Map<Id,Opportunity>)oOpp;
        Opportunity oldOpp = null;
        for(Opportunity o : newRecords.values()) {
            oldOpp = oldRecords.get(o.Id);
			if(oldOpp != null && o.Stagename != oldOpp.Stagename) {
                if(String.isNotBlank(o.ProcessedStages__c)) {
                    if(isNewValue(oldOpp.Stagename, o.ProcessedStages__c.split(';'))) {
                        o.ProcessedStages__c = o.ProcessedStages__c + ';' + oldOpp.Stagename;
                    }				
                } else {
                    o.ProcessedStages__c = oldOpp.Stagename;
                }
                if(isNewValue(o.Stagename, o.ProcessedStages__c.split(';'))) {
					o.ProcessedStages__c = o.ProcessedStages__c + ';' + o.Stagename;					
                }
			}
		}
    }

    private static Boolean isNewValue(String newValue, String[] selectedValues) {
		for (String v : selectedValues) {
			if(v.equalsIgnoreCase(newValue)) {
				return false;
			}
		}
		return true;
	}
}