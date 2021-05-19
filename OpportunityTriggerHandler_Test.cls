/*******************************************************************
Author:         Surbhi Bhati
Description:    Test class for OpportunityTriggerHandler

History:
Date            Author              Comments
-------------------------------------------------------------------
20-02-2019      Surbhi Bhati        Created
*******************************************************************/
@isTest
private  class OpportunityTriggerHandler_Test {
	private static LoanApplicationDataProviderFactory loanDataProviderFactory = new LoanApplicationDataProviderFactory();
	private static Map<String,object> cuserRoleMaster = loanDataProviderFactory.getCreditUserRoleMaster();
	private static Map<String,object> suserRoleMaster = loanDataProviderFactory.getSalesUserRoleMaster();
	private static Map<String,object> testDataMap = loanDataProviderFactory.getTestDataMap();
	private static Map<String,object> sObjectNameVsRecord = loanDataProviderFactory.getSObjectNameVsRecord();

	@isTest
	private static void afterUpdateTest(){
		Map<String,object> loanApplicationTree = loanDataProviderFactory.getLoanApplicationTree();
		Opportunity loan = (Opportunity)loanApplicationTree.get('loanApplication');
		loan.StageName = 'Credit Underwriting';
		loan.Intent__c = '{"context": "UI_NEXT_STAGE_CLICK"}';
		loan.Primary_Sales_User__c = ((User_Role_Master__c)suserRoleMaster.get('ASM')).Id;
		loan.Primary_Credit_User__c = ((User_Role_Master__c)cuserRoleMaster.get('ACM')).Id;
		update loan;
		loan.MCP_Bypass__c = 'Yes';
		loan.Reason_to_Bypass_MCP__c ='Financials';
		loan.Approved_Loan_Amount__c = 200000;
		update loan;
		system.assertEquals('Yes',loan.MCP_Bypass__c);
	}

	@isTest
	private static void finnoneTest(){
		createMovedToLMSAndCentralOpsActivity();
		Test.startTest();
        
		loanDataProviderFactory.setStage(GlobalConstants.STAGE_MOVED_TO_LMS);
		Map<String,object> loanApplicationTree = loanDataProviderFactory.getLoanApplicationTree();
		Opportunity loan = (Opportunity)loanApplicationTree.get('loanApplication');

		loan.Moved_To_Finnone__c = GlobalConstants.MOVED_TO_FINNONE_SUCCESS;
		update loan;
		Test.stopTest();
		system.assert(true);

	}

	private static void createMovedToLMSAndCentralOpsActivity(){
		List<Activity_Dictionary__c> branchOpsAd = Database.query(QueryBuilder.build('Activity_Dictionary__c','Canonical_Name__c = \'Branch Ops\' LIMIT 1',false));
		List<Workflow_Activity_Metadata__c> branchOpsWAM = Database.query(QueryBuilder.build('Workflow_Activity_Metadata__c','External_Id__c = \'PSBL_NTB_Branch_Ops\' LIMIT 1',false));

		Activity_Dictionary__c movedToLMSAD = branchOpsAd[0].clone(false,true,false,false);
		movedToLMSAD.External_Id__c = 'Moved_To_LMS';
		movedToLMSAD.Canonical_Name__c = 'Moved To LMS';
		movedToLMSAD.Handler_Class_Name__c = 'MovedToLMSStageChangeActivity';
		insert movedToLMSAD;
		Workflow_Activity_Metadata__c movedToLMSWAM = branchOpsWAM[0].clone(false,true,false,false);
		movedToLMSWAM.Workflow__c = ((List<Workflow_Dictionary__c>)testDataMap.get('workflowRecord'))[0].Id;
		movedToLMSWAM.Activity__c = movedToLMSAD.Id;
		movedToLMSWAM.Is_Active__c = true;
		movedToLMSWAM.External_Id__c = 'PSBL_NTB_Moved_To_LMS';
		movedToLMSWAM.Application_Stages__c = GlobalConstants.STAGE_MOVED_TO_LMS;
		movedToLMSWAM.Next_Stage__c = GlobalConstants.STAGE_CENTRAL_OPS;
		movedToLMSWAM.Allocation__c = 'Auto';
		movedToLMSWAM.POST_ORCHESTRATION_ACTIVITIES_SEQUENCE__C = null;
		movedToLMSWAM.Mandatory_Application_Stages__c = GlobalConstants.STAGE_MOVED_TO_LMS;
		movedToLMSWAM.Mandatory_Activities__c = null;
		insert movedToLMSWAM;
		Activity_Dictionary__c centralOpsAD = branchOpsAd[0].clone(false,true,false,false);
		centralOpsAD.External_Id__c = 'Central_Ops';
		centralOpsAD.Canonical_Name__c = 'Central Ops';
		centralOpsAD.Handler_Class_Name__c = 'CentralOppsStageChangeActivity';
		insert centralOpsAD;
		Workflow_Activity_Metadata__c centralOpsWAM = branchOpsWAM[0].clone(false,true,false,false);
		centralOpsWAM.Workflow__c = ((List<Workflow_Dictionary__c>)testDataMap.get('workflowRecord'))[0].Id;
		centralOpsWAM.Activity__c = centralOpsAD.Id;
		centralOpsWAM.Is_Active__c = true;
		centralOpsWAM.External_Id__c = 'PSBL_NTB_Central_Ops';
		centralOpsWAM.Application_Stages__c = GlobalConstants.STAGE_CENTRAL_OPS;
		centralOpsWAM.Allocation__c = 'Auto';
		centralOpsWAM.POST_ORCHESTRATION_ACTIVITIES_SEQUENCE__C = null;
		centralOpsWAM.Mandatory_Application_Stages__c = GlobalConstants.STAGE_CENTRAL_OPS;
		centralOpsWAM.Mandatory_Activities__c = null;
		insert centralOpsWAM;
	}
    
    @isTest
    private static void testProgramTypeChange() {
		String recordTypeId = Schema.SObjectType.Common_Master__c.getRecordTypeInfosByDeveloperName().get('Program_Types').getRecordTypeId();
        Common_Master__c pt = new Common_Master__c(Program_Category__c = 'Banking', 
                                                   Start_Date__c = Date.today(), 
                                                   End_Date__c = Date.today().addMonths(1), 
                                                   RecordTypeId = recordTypeId, 
                                                   Program_Type__c = 'ABB Program'
                                                  );
        insert pt;
        
        Map<String,object> loanApplicationTree = loanDataProviderFactory.getLoanApplicationTree();
		Opportunity loan = (Opportunity)loanApplicationTree.get('loanApplication');
        Opportunity newLoan = new Opportunity(Id = loan.Id, Program_Category__c = 'Banking', Program_Type__c = loan.Program_Type__c, Current_Customer_Segment__c = 'WOW', Eligible_loan_amount__c = 3000);
        Opportunity oldLoan = new Opportunity(Id = loan.Id, Program_Category__c = 'Banking', Program_Type__c = pt.Id, Current_Customer_Segment__c = 'WOW', Eligible_loan_amount__c = 3000);
        System.debug('-PT0-' + loan.Program_Type__c + '=' + pt.Id);
        OpportunityTriggerHandler handler = new OpportunityTriggerHandler();
        handler.resetFieldsAndActivitiesOnProgramTypeChange(new map<Id, Opportunity> {loan.Id => newLoan}, new map<Id, Opportunity> {loan.Id => oldLoan});
    }
    
    @isTest
	private static void GSTINTest(){
        Test.startTest();
		Map<String,object> loanApplicationTree = loanDataProviderFactory.getLoanApplicationTree();
		Opportunity loan = (Opportunity)loanApplicationTree.get('loanApplication');
		loan.GSTIN__c = '12456gh';
		update loan;
        Test.stopTest();
	}
    
    @isTest
	private static void GSTINTest2(){
        Test.startTest();
		Map<String,object> loanApplicationTree = loanDataProviderFactory.getLoanApplicationTree();
		Opportunity loan = (Opportunity)loanApplicationTree.get('loanApplication');
		loan.GSTIN__c = '12456gh';
		update loan;
        loan.GSTIN__c = NULL;
        update loan;
        Test.stopTest();
	}
}